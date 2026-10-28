// Reads sdk-schema.json's `commands`, `events` and `types` into TypeSchema.
// It reads a named type only when TypeSchema asks for it, so the
// app's build depends only on the types its own commands and events reach.

struct TypeSchemaParser {
    typealias Schema = TypeSchema

    let document: SchemaJSON
    private let named: [String: SchemaJSON]

    init(document: SchemaJSON) throws(TypeSchemaError) {
        self.document = document
        guard let types = (document["types"] ?? .object([:])).object else {
            throw TypeSchemaError(path: "$.types", message: "must be an object")
        }
        self.named = types
    }

    /// The commands `client` calls (absent `clients` is every client), in name order.
    func commands(client: String) throws(TypeSchemaError) -> [Schema.Command] {
        guard let members = document["commands"]?.object else {
            throw TypeSchemaError(path: "$.commands", message: "must be an object")
        }
        var out: [Schema.Command] = []
        for name in members.keys.sorted() {
            guard let node = members[name] else { continue }
            let path = "$.commands.\(name)"
            guard try serves(client, path: path, node: node) else { continue }
            var methodID: UInt16?
            if let value = node["method_id"] {
                guard let raw = value.integer, let id = UInt16(exactly: raw) else {
                    throw TypeSchemaError(path: "\(path).method_id", message: "must be a u16 (family << 8 | ordinal)")
                }
                methodID = id
            }
            guard case .object(let request) = try expression(try required(node, "request", path: path), path: "\(path).request") else {
                throw TypeSchemaError(path: "\(path).request", message: "must be an object type")
            }
            guard let result = node["result"] else { throw TypeSchemaError(path: "\(path).result", message: "is missing") }
            out.append(Schema.Command(
                name: name,
                methodID: methodID,
                request: request,
                result: try expression(result, path: "\(path).result")
            ))
        }
        return out
    }

    /// The events `client` receives (absent `clients` is every client), in name order.
    func events(client: String) throws(TypeSchemaError) -> [Schema.Event] {
        guard let table = document["events"] else { return [] }
        guard let members = table.object else { throw TypeSchemaError(path: "$.events", message: "must be an object") }
        var out: [Schema.Event] = []
        for name in members.keys.sorted() {
            guard let node = members[name] else { continue }
            let path = "$.events.\(name)"
            guard try serves(client, path: path, node: node) else { continue }
            let payload = try expression(try required(node, "payload", path: path), path: "\(path).payload")
            out.append(Schema.Event(name: name, payload: payload))
        }
        return out
    }

    /// The named type `name` (`$.types.<name>`).
    func namedType(_ name: String) throws(TypeSchemaError) -> Schema.TypeExpr {
        guard let node = named[name] else {
            throw TypeSchemaError(path: "$.types.\(name)", message: "is referenced but not declared")
        }
        return try expression(node, path: "$.types.\(name)")
    }

    // Expressions -----------------------------------------------------------

    private func expression(_ node: SchemaJSON, path: String) throws(TypeSchemaError) -> Schema.TypeExpr {
        guard let kind = node["kind"]?.string else { throw TypeSchemaError(path: "\(path).kind", message: "must be a string") }
        switch kind {
        case "scalar":
            guard let raw = node["name"]?.string, let scalar = Schema.Scalar(rawValue: raw) else {
                throw TypeSchemaError(path: "\(path).name", message: "is not a scalar this generator knows")
            }
            return .scalar(scalar)
        case "literal":
            switch node["value"] {
            case .bool?, .integer?, .string?: return .literal(node["value"] ?? .null)
            default: throw TypeSchemaError(path: "\(path).value", message: "must be a string, integer or boolean literal")
            }
        case "enum":
            return .enumeration(try enumeration(node, path: path))
        case "object":
            return .object(try object(node, path: path))
        case "alias":
            return .alias(try expression(try required(node, "target", path: path), path: "\(path).target"))
        case "tagged_union":
            return .taggedUnion(try taggedUnion(node, path: path))
        case "untagged_union":
            guard case .array(let items)? = node["variants"], items.count >= 2 else {
                throw TypeSchemaError(path: "\(path).variants", message: "must list at least two variants")
            }
            var variants: [Schema.TypeExpr] = []
            for (index, item) in items.enumerated() {
                let variant = try expression(item, path: "\(path).variants[\(index)]")
                guard case .ref = variant else {
                    throw TypeSchemaError(path: "\(path).variants[\(index)]", message: "an untagged variant must be a named type")
                }
                variants.append(variant)
            }
            return .untaggedUnion(variants)
        case "array":
            return .array(try expression(try required(node, "items", path: path), path: "\(path).items"))
        case "map":
            return .map(try expression(try required(node, "values", path: path), path: "\(path).values"))
        case "ref":
            guard let name = node["name"]?.string else { throw TypeSchemaError(path: "\(path).name", message: "must be a type name") }
            guard named[name] != nil else { throw TypeSchemaError(path: path, message: "refers to undeclared type \(name)") }
            return .ref(name)
        case "opaque_json":
            return .opaqueJSON
        default:
            throw TypeSchemaError(path: "\(path).kind", message: "\(kind) is not a type this generator knows")
        }
    }

    private func enumeration(_ node: SchemaJSON, path: String) throws(TypeSchemaError) -> Schema.Enumeration {
        guard case .array(let items)? = node["values"], !items.isEmpty else {
            throw TypeSchemaError(path: "\(path).values", message: "must be a non-empty array")
        }
        var values: [String] = []
        for item in items {
            guard let value = item.string else {
                throw TypeSchemaError(path: "\(path).values", message: "Swift enums take string values only")
            }
            values.append(value)
        }
        let fallback = node["fallback"]?.string
        if let fallback, !values.contains(fallback) {
            throw TypeSchemaError(path: "\(path).fallback", message: "\(fallback) is not one of the values")
        }
        return Schema.Enumeration(values: values, fallback: fallback)
    }

    private func object(_ node: SchemaJSON, path: String) throws(TypeSchemaError) -> Schema.Object {
        guard let members = node["fields"]?.object else { throw TypeSchemaError(path: "\(path).fields", message: "must be an object") }
        var fields: [Schema.Field] = []
        for name in members.keys.sorted() {
            guard let member = members[name] else { continue }
            fields.append(try field(member, name: name, path: "\(path).fields.\(name)"))
        }
        return Schema.Object(fields: fields)
    }

    private func field(_ node: SchemaJSON, name: String, path: String) throws(TypeSchemaError) -> Schema.Field {
        let type = try expression(try required(node, "type", path: path), path: "\(path).type")
        let required: Bool
        switch node["presence"]?.string {
        case "required": required = true
        case "optional": required = false
        default: throw TypeSchemaError(path: "\(path).presence", message: "must be required or optional")
        }
        guard let nullable = node["nullable"]?.bool else {
            throw TypeSchemaError(path: "\(path).nullable", message: "must be a boolean")
        }
        let omitNil = node["omit_nil"]?.bool ?? false
        if omitNil, required {
            throw TypeSchemaError(path: "\(path).omit_nil", message: "is for optional members only")
        }
        var aliases: [String] = []
        if case .array(let items)? = node["aliases"] {
            for item in items {
                guard let alias = item.string else { throw TypeSchemaError(path: "\(path).aliases", message: "must be strings") }
                aliases.append(alias)
            }
        }
        if case .literal = type, nullable {
            throw TypeSchemaError(path: path, message: "a literal member cannot be nullable")
        }
        return Schema.Field(
            name: name,
            type: type,
            required: required,
            nullable: nullable,
            defaultValue: required ? nil : node["default"],
            omitNil: omitNil,
            aliases: aliases,
            summary: node["description"]?.string
        )
    }

    private func taggedUnion(_ node: SchemaJSON, path: String) throws(TypeSchemaError) -> Schema.TaggedUnion {
        guard let tag = node["tag"]?.string else { throw TypeSchemaError(path: "\(path).tag", message: "must be a string") }
        guard let members = node["variants"]?.object, !members.isEmpty else {
            throw TypeSchemaError(path: "\(path).variants", message: "must be a non-empty object")
        }
        var variants: [Schema.Variant] = []
        for key in members.keys.sorted() {
            let variantPath = "\(path).variants.\(key)"
            guard let member = members[key], case .object(let object) = try expression(member, path: variantPath) else {
                throw TypeSchemaError(path: variantPath, message: "a tagged variant must be an object type")
            }
            let tagField = object.fields.first { $0.name == tag }
            guard let tagField, tagField.required, tagField.type == .literal(.string(key)) else {
                throw TypeSchemaError(path: variantPath, message: "needs a required member \(tag) with literal \"\(key)\"")
            }
            variants.append(Schema.Variant(tag: key, object: object))
        }
        return Schema.TaggedUnion(tagField: tag, variants: variants)
    }

    // Plumbing --------------------------------------------------------------

    private func serves(_ client: String, path: String, node: SchemaJSON) throws(TypeSchemaError) -> Bool {
        guard let value = node["clients"] else { return true }
        guard case .array(let items) = value else {
            throw TypeSchemaError(path: "\(path).clients", message: "must be an array of client names")
        }
        return items.contains(.string(client))
    }

    private func required(_ node: SchemaJSON, _ key: String, path: String) throws(TypeSchemaError) -> SchemaJSON {
        guard let value = node[key] else { throw TypeSchemaError(path: "\(path).\(key)", message: "is missing") }
        return value
    }
}
