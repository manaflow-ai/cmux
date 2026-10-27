import Foundation

/// Resolves a command's type expressions against `$.types`.
struct RequestTypeReader {
    let types: [String: SchemaJSON]
    /// Names a nested type must not take: the generated members and every type a member could name.
    private let taken: Set<String>

    init(types: [String: SchemaJSON]) {
        self.types = types
        let generated: Set = ["Response", "CodingKeys", "JSONValue", "EmptyResponse", "Data"]
        taken = Set(types.keys).union(generated).union(RequestSchema.scalars.values)
            .union(RequestSchema.idTypes.values)
    }

    func object(_ node: SchemaJSON, path: String, name: String) throws(RequestSchemaError) -> WireType.Object {
        guard node["kind"]?.string == "object", let members = node["fields"]?.object else {
            throw RequestSchemaError(path: path, message: "must be an inline object")
        }
        var fields: [WireType.Field] = []
        var seen: [String: String] = [:]
        for wire in members.keys.sorted() {
            guard let member = members[wire] else { continue }
            let field = try self.field(member, wire: wire, path: "\(path).fields.\(wire)")
            if let other = seen.updateValue(wire, forKey: field.swift) {
                throw RequestSchemaError(path: "\(path).fields.\(wire)",
                                         message: "is \(field.swift) in Swift, as \(other) is")
            }
            fields.append(field)
        }
        return WireType.Object(name: name, fields: fields.filter(\.required) + fields.filter { !$0.required })
    }

    private func field(_ member: SchemaJSON, wire: String, path: String) throws(RequestSchemaError) -> WireType.Field {
        guard let presence = member["presence"]?.string, ["required", "optional"].contains(presence) else {
            throw RequestSchemaError(path: "\(path).presence", message: "must be required or optional")
        }
        guard let nullable = member["nullable"]?.bool else {
            throw RequestSchemaError(path: "\(path).nullable", message: "must be a boolean")
        }
        guard let type = member["type"] else { throw RequestSchemaError(path: path, message: "needs a type") }
        let notes = [member["description"]?.string, member["capability"]?.string.map { "Daemon capability `\($0)`." }]
        let description = notes.compactMap { $0 }.joined(separator: "\n")
        return WireType.Field(
            wire: wire,
            swift: SwiftNaming.propertyName(wire),
            type: try self.type(type, path: "\(path).type", field: wire, nested: SwiftNaming.typeName(wire)),
            required: presence == "required",
            nullable: nullable,
            omitNil: try RequestSchema.flag(member, "omit_nil", path: path),
            defaultValue: member["default"],
            description: description.isEmpty ? nil : description
        )
    }

    /// The Swift type of `node`; `field` is the wire field it types (for typed ids),
    /// `nested` the name an inline object or enum gets.
    func type(_ node: SchemaJSON, path: String, field: String, nested: String) throws(RequestSchemaError) -> WireType {
        let name = taken.contains(nested) ? nested + "Value" : nested
        switch node["kind"]?.string ?? "" {
        case "scalar":
            guard let scalar = node["name"]?.string, let swift = RequestSchema.scalars[scalar] else {
                throw RequestSchemaError(path: "\(path).name", message: "is not a known scalar")
            }
            return .named(swift)
        case "ref":
            guard let target = node["name"]?.string else {
                throw RequestSchemaError(path: "\(path).name", message: "must be a type name")
            }
            return try ref(target, path: path, field: field)
        case "array":
            guard let items = node["items"] else { throw RequestSchemaError(path: path, message: "needs items") }
            return .array(try type(items, path: "\(path).items", field: field, nested: nested + "Item"))
        case "map":
            guard let values = node["values"] else { throw RequestSchemaError(path: path, message: "needs values") }
            return .map(try type(values, path: "\(path).values", field: field, nested: nested + "Value"))
        case "object":
            return .object(try object(node, path: path, name: name))
        case "enum":
            return .enumeration(try enumeration(node, path: path, name: name))
        case "literal":
            switch node["value"] {
            case .string(let value)?: return .literal(swift: TableEmitter.literal(value), base: "String")
            case .bool(let value)?: return .literal(swift: "\(value)", base: "Bool")
            case .integer(let value)?: return .literal(swift: "\(value)", base: "Int64")
            default: throw RequestSchemaError(path: "\(path).value", message: "must be a string, boolean or integer")
            }
        case let kind:
            throw RequestSchemaError(path: path, message: "kind \"\(kind)\" has no inline request form")
        }
    }

    private func ref(_ target: String, path: String, field: String) throws(RequestSchemaError) -> WireType {
        if target == "Id" { return .named(RequestSchema.idTypes[field] ?? "UInt64") }
        if let swift = RequestSchema.aliasTypes[target] { return .named(swift) }
        guard let declared = types[target] else {
            throw RequestSchemaError(path: "\(path).name", message: "\(target) is not in $.types")
        }
        switch declared["kind"]?.string {
        case "opaque_json":
            return .json(schema: target)
        case "alias":
            guard let aliased = declared["target"] else {
                throw RequestSchemaError(path: "$.types.\(target)", message: "an alias needs a target")
            }
            return try type(aliased, path: "$.types.\(target).target", field: field, nested: target)
        default:
            return .named(target)
        }
    }

    private func enumeration(
        _ node: SchemaJSON,
        path: String,
        name: String
    ) throws(RequestSchemaError) -> WireType.Enumeration {
        guard case .array(let values)? = node["values"], !values.isEmpty else {
            throw RequestSchemaError(path: "\(path).values", message: "must be a non-empty array")
        }
        var cases: [WireType.Enumeration.Case] = []
        for value in values {
            guard let wire = value.string else {
                throw RequestSchemaError(path: "\(path).values", message: "an inline enum holds strings only")
            }
            let swift = SwiftNaming.propertyName(wire)
            guard !cases.contains(where: { $0.swift == swift }) else {
                throw RequestSchemaError(path: "\(path).values", message: "two values are the case \(swift)")
            }
            cases.append(WireType.Enumeration.Case(swift: swift, wire: wire))
        }
        var fallback: String?
        if let value = node["fallback"] {
            guard let wire = value.string, let match = cases.first(where: { $0.wire == wire }) else {
                throw RequestSchemaError(path: "\(path).fallback", message: "must be one of the values")
            }
            fallback = match.swift
        }
        return WireType.Enumeration(name: name, cases: cases, fallback: fallback)
    }
}
