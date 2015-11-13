Merge    = require 'merge'
Uuid     = require 'node-uuid'
Utils = require './utils'
Base  = require './base'

log = require('./log')(module)

module.exports = class Factory extends Base

	constructor : (opts = {}) ->
		super

	_listAssertions: (doc, opts, depth = 0) ->
		factory = doc.schema.options.jsonldFactory
		opts = Merge @opts, opts
		# opts.keep_id or= true
		ret = {}
		flatDoc = doc.toJSON()
		# Set the @id to a dereferenceable URI
		ret['@id'] = factory.uriForInstance(doc)
		# TODO is this the right behavior
		ret['@context'] or= {}
		schemaContext = doc.schema.options['@context']
		if schemaContext
			shortName = "_type_#{Utils.lastUriSegment(schemaContext['@id'])}"
			ret['@type'] = shortName
			ret['@context'][shortName] = schemaContext

		# Walk the schema path definitions, adding their @context under their
		# path into the context for the schema
		for schemaPathName of doc.toJSON()
			schemaPathDef = doc.schema.paths[schemaPathName]
			propDef = doc[schemaPathName]
			# skip internal fields
			continue if Utils.INTERNAL_FIELD_REGEX.test schemaPathName
			if not schemaPathDef
				#XXX TODO
				log.error "Error: #{schemaPathName} FIXME"
				continue
			# Add property data to the context
			propContext = schemaPathDef.options?['@context']
			if propContext
				ret['@context'][schemaPathName] = propContext
			schemaPathOptions = schemaPathDef.options
			if Utils.isJoinSingle schemaPathOptions
				# console.log "#{schemaPathName}: Utils.isJoinSingle"
				# console.log propDef
				# XXX recursive
				ret[schemaPathName] = factory._listAssertions(propDef, opts)
			else if Utils.isJoinMulti schemaPathOptions
				# console.log "#{schemaPathName}: Utils.isJoinMulti"
				ret[schemaPathName] = []
				for subDoc in propDef
					# XXX recursive
					ret[schemaPathName].push factory._listAssertions(subDoc, opts, depth + 1)
			else
				# console.log "#{schemaPathName}: standard: '#{flatDoc[schemaPathName]}'"
				ret[schemaPathName] = flatDoc[schemaPathName]
		# Delete '_id' unless explicitly kept
		# if opts.keep_id
		#     ret._id = doc._id
		# XXX won't work for rdf type and such
		# if opts.filter_predicate
		#     predicates_to_keep = (Utils.lastUriSegment(uri) for uri in opts.filter_predicate)
		#     log.silly "predicates to keep", predicates_to_keep
		#     for path of ret
		#         continue if Utils.INTERNAL_FIELD_REGEX.test(path) or Utils.JSONLD_FIELD_REGEX.test(path)
		#         delete ret[path] unless path in predicates_to_keep
		return ret

	_createDocumentFromObject : (model, obj) ->
		for schemaPathName of obj
			schemaPathDef = model.schema.paths[schemaPathName]
			schemaPathOptions = schemaPathDef.options
			Utils.dumplog schemaPathOptions
			if 'refOne' of schemaPathOptions
				obj[schemaPathName] = Utils.lastUriSegment(obj[schemaPathName])
			else if 'refMany' of schemaPathOptions
				swap = []
				for uri of obj[schemaPathName]
					swap.push Utils.lastUriSegment uri
				obj[schemaPathName] = swap
		return new model(obj)

	# XXXX TODO do this by hand
	_findOneAndPopulate : (model, searchDoc, cb) ->
		builder = model.findOne(searchDoc)
		for schemaPathName, schemaPathDef of model.schema.paths
			schemaPathType = schemaPathDef.options
			if Utils.isJoinSingle(schemaPathType) or Utils.isJoinMulti(schemaPathType)
				builder.populate(schemaPathName)
		return builder.exec cb

	_listDescription: (model, opts) ->
		onto = []
		# Class def
		onto.push model.schema.options['@context']
		# Properties def
		for schemaPathName, schemaPathDef of model.schema.paths
			# skip internal fields
			continue if Utils.INTERNAL_FIELD_REGEX.test schemaPathName
			propCtx = schemaPathDef.options?['@context']
			continue unless propCtx
			propCtx['@id'] = @curie.shorten @uriForClass(schemaPathName)
			# propCtx['@type'] = 'rdfs:Property'
			onto.push propCtx
		return onto

	createPlugin: (schema, opts) ->
		factory = this
		opts or= {}
		opts = Merge(@opts, opts)
		return (schema) ->
			#
			# Every model can have an '@id' field
			#
			schema.add({
				'@id': {
					'type': String
				}
			})
			#
			# We enforce UUIDs for all the things
			#
			schema.add _id : {
				type: String
				validate: factory.validators.UUID
				# required: yes
			}
			#
			# Ensure every document to have a valid _id (a UUID)
			#
			schema.pre 'save', (next) ->
				doc = this
				if doc.isNew and not doc._id
					doc.setValue '_id', Uuid.v1()
				next()
			#
			# Allow export of the Linked Data description of the data
			#
			schema.methods.jsonldABox = (innerOpts, cb) ->
				if typeof innerOpts == 'function' then [cb, innerOpts] = [innerOpts, {}]
				doc = this
				innerOpts = Merge(opts, innerOpts)
				if cb
					return factory.serialize factory._listAssertions(doc, innerOpts), innerOpts, cb
				else
					return factory._listAssertions(doc, innerOpts)
			#
			# Get the uri of this document
			#
			schema.methods.uri = () ->
				return factory.uriForInstance(this)
			#
			# Get the uri of a class
			#
			schema.methods.uriForClass = (clazz) ->
				return factory.uriForClass(clazz)
			#
			# Return the TBox of the model (definitions, @context etc.)
			#
			schema.statics.jsonldTBox = (innerOpts, cb) ->
				if typeof innerOpts == 'function' then [cb, innerOpts] = [innerOpts, {}]
				model = this
				innerOpts = Merge(opts, innerOpts)
				if cb
					return factory.serialize factory._listDescription(model, innerOpts), innerOpts, cb
				return factory._listDescription(model, innerOpts)
			#
			# List of all proper fields
			#
			schema.statics.properFields = ->
				(v for v of @schema.paths when not Utils.INTERNAL_FIELD_REGEX.test(v) and
					not Utils.JSONLD_FIELD_REGEX.test v)
			#
			# Find one document and retrieve all inter-collection joins
			#
			schema.statics.findOneAndPopulate = (searchDoc, cb) ->
				factory._findOneAndPopulate(this, searchDoc, cb)
			#
			# Instantiate a document from a JSON object
			#
			schema.statics.fromJSON = (obj, cb) ->
				factory._createDocumentFromObject(this, obj, cb)

	createSchema : (className, schemaDef, mongooseOptions) ->
		mongooseOptions or= {}
		mongooseOptions.jsonldFactory = this
		# JSON-LD infos about the class
		classUri = @curie.shorten @uriForClass(className)
		schemaContext = Merge schemaDef['@context'], {
			'@id': classUri
		}
		# Remove @context from the schema definition and move it to the schema options
		delete schemaDef['@context']
		mongooseOptions['@context'] = schemaContext
		schemaContext['rdf:type'] or= [{'@id': 'owl:Thing'}]
		schema = new(@mongoose.base.constructor)().Schema({}, mongooseOptions)
		schema.plugin(@createPlugin(schema))
		# JSON-LD info about properties
		for propName, propDef of schemaDef
			# handle validate functions
			if propDef['validate'] and typeof propDef['validate'] is 'string'
				validateFn = @validators[propDef['validate']]
				if not validateFn
					throw new Error("No function handling #{propDef.validate}")
				else
					propDef['validate'] = validateFn
			# handling flat types
			if propDef['type'] and propDef['type'] and typeof propDef['type'] is 'string'
				propDef['type'] = @typeMap[propDef['type']]
			# handle required
			if not propDef.required
				propDef.required = no
			# handle property @context
			pc = propDef['@context'] || {}
			if typeof pc isnt 'object'
				throw new Error("UNHANDLED @context not being an object, but #{typeof pc}")
			# Canonicalize prefixed names
			for x,y of propDef['@context']
				if typeof y is 'string'
					pc[@curie.shorten @curie.expand x] = @curie.shorten @curie.expand y
				else
					pc[@curie.shorten @curie.expand x] = y
			# TODO this was wrong
			# # rdf:type rdfs:Property
			# pc['@type'] or= []
			# if typeof pc['@type'] is 'string'
			#     pc['@type'] = [pc['@type']]
			# pc['@type'].push {'@id': 'rdfs:Property'}
			# enum values -> owl:oneOf
			enumValues = propDef.enum
			if enumValues and enumValues.length
				pc['rdfs:range'] = {
					'owl:oneOf': enumValues
					'@type': 'xsd:string'
				}
			if not pc['rdfs:range']
				switch propDef.type
					when String, 'String'
						pc['rdfs:range'] = {'@id': 'xsd:string'}
					else
						# XXX do nothing
						null
			# schema:domainIncludes (rdfs:domain)
			pc['schema:domainIncludes'] or= []
			pc['schema:domainIncludes'].push {'@id': classUri}
			propOpts = {
				'@context': pc
			}
			delete propDef['@context']
			# XXX TODO
			# handle dbrefs
			#
			if 'refMany' of propDef
				propDef.type = String
				propDef.ref = propDef.refMany
			else if 'refOne' of propDef
				propDef.type = String
				propDef.ref = propDef.refOne

			schema.add("#{propName}": propDef)
			schema.paths[propName].options or= {}
			schema.paths[propName].options['@context'] = pc
		return schema
	
	createModel: (name, schema) ->
		model = @mongoose.model(name, schema)
		# Create indexes
		schema.options.emitIndexErrors = true
		indexProp = {}
		indexProp[k] = 1 for k in model.properFields()
		schema.index(indexProp)
		# Log errors
		model.on 'error', (err) ->
			log.error err
		model.on 'index', (err) ->
			return log.error err if err
			return log.info 'Index built successfully'
		return model
