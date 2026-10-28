import Foundation

// Reads the binary layouts of the hot messages out of cmux-tui/spec/sdk-schema.json for
// HotEmitter (p05-ipc-183; cmux-tui/spec/transports.md, "Binary payload layouts"). It mirrors
// cmux-tui/crates/cmux-ipc/build-support/hot_codec.rs rule for rule and names every type the way
// it does, so the Rust and Swift codecs write the same bytes
// (cmux-tui/spec/fixtures/ipc-hot-codec/golden.json).
//
// A command with `payload: "binary"` has a layout for its request and one for its result; an event
// with `encoding: "binary"` has one for its payload. An object's fields go in the byte order of their
// wire names, without its literal fields; optional and nullable fields get a tag byte; an enum is
// the u8 index of its value; a string is a u16 byte length (at most `max_bytes`) and its UTF-8; an
// array a u16 count (at most its field's `max_items`, else its type's) and its items. A field's bounds
// are the layout's only: JSON decoders do not read them, and a value over one goes as JSON.

/// A field's layout bounds: `maxBytes` bounds each string it reaches, `maxItems` the field's own array.
struct FieldBounds: Equatable {
    var maxBytes: Int64?
    var maxItems: Int64?
}

/// Why the hot layouts cannot be generated. `path` is a JSON path into sdk-schema.json.
struct HotSchemaError: Error, Equatable, CustomStringConvertible {
    let path: String
    let message: String

    var description: String { "sdk-schema.json: \(path): \(message)" }
}

/// Every binary layout of the schema and the types they reach.
struct HotSchema: Equatable {
    /// What a value is on the wire.
    indirect enum WireType: Equatable {
        case bool, u16, u32, u64, i32, i64, f32, f64
        /// A string of at most `maxBytes` UTF-8 bytes.
        case string(maxBytes: UInt16)
        /// A generated enum, by Rust type name.
        case enumeration(String)
        /// A generated struct, by Rust type name.
        case object(String)
        case array(items: WireType, maxItems: UInt16)
    }

    struct Field: Equatable {
        /// The JSON member name.
        let wire: String
        let type: WireType
        /// Optional or nullable: a tag byte comes first.
        let tagged: Bool
        /// Present only for a required, nullable field: JSON writes `null` for nil.
        let writesNull: Bool
    }

    struct Struct: Equatable {
        let name: String
        let fields: [Field]
        /// Literal members (`event`): JSON only, never on the wire.
        let literals: [Literal]
    }

    struct Literal: Equatable {
        let wire: String
        let value: String
    }

    struct Enumeration: Equatable {
        let name: String
        let values: [String]
        /// The value JSON decodes an unknown string to (`fallback`); the wire has no unknown index.
        let fallback: String?
    }

    enum Part: String, Equatable {
        case request, result, event

        var rust: String { String(rawValue.prefix(1)).uppercased() + String(rawValue.dropFirst()) }
    }

    struct Message: Equatable {
        let name: String
        let part: Part
        let wireID: UInt16
        let layoutVersion: UInt8
        /// The struct of its body.
        let type: String
    }

    private(set) var messages: [Message] = []
    private(set) var structs: [String: Struct] = [:]
    private(set) var enums: [String: Enumeration] = [:]
    private let types: [String: SchemaJSON]

    init(sdkSchema: Data) throws(HotSchemaError) {
        let document: SchemaJSON
        do {
            document = try JSONDecoder().decode(SchemaJSON.self, from: sdkSchema)
        } catch {
            throw HotSchemaError(path: "$", message: "not JSON: \(error)")
        }
        try self.init(document: document)
    }

    init(document: SchemaJSON) throws(HotSchemaError) {
        types = document["types"]?.object ?? [:]
        for (name, node) in try Self.members(document, "commands") {
            let path = "$.commands.\(name)"
            guard let version = try Self.layoutVersion(node, key: "payload", path: path) else { continue }
            let id = try Self.wireID(node, key: "method_id", path: path)
            for part in [Part.request, Part.result] {
                guard let body = node[part.rawValue] else { throw HotSchemaError(path: "\(path).\(part.rawValue)", message: "missing") }
                let type = try self.body(body, fallback: Self.pascal(name) + part.rust, path: "\(path).\(part.rawValue)")
                messages.append(Message(name: name, part: part, wireID: id, layoutVersion: version, type: type))
            }
        }
        for (name, node) in try Self.members(document, "events") {
            let path = "$.events.\(name)"
            guard let version = try Self.layoutVersion(node, key: "encoding", path: path) else { continue }
            let id = try Self.wireID(node, key: "event_id", path: path)
            guard let payload = node["payload"] else { throw HotSchemaError(path: "\(path).payload", message: "missing") }
            let type = try body(payload, fallback: Self.pascal(name) + "Event", path: "\(path).payload")
            messages.append(Message(name: name, part: .event, wireID: id, layoutVersion: version, type: type))
        }
    }

    /// `resize-attached-view` -> `ResizeAttachedView`, `at_bottom` -> `AtBottom` (the Rust rule).
    static func pascal(_ name: String) -> String {
        name.split(whereSeparator: { !($0.isASCII && ($0.isLetter || $0.isNumber)) })
            .map { String($0.prefix(1)).uppercased() + String($0.dropFirst()) }
            .joined()
    }

    /// Byte order of UTF-8, the order Rust sorts names in.
    static func byteOrder(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
    }

    // Reading ---------------------------------------------------------------

    private static func members(_ document: SchemaJSON, _ key: String) throws(HotSchemaError) -> [(String, SchemaJSON)] {
        guard let object = document[key]?.object else { throw HotSchemaError(path: "$.\(key)", message: "must be an object") }
        return object.keys.sorted(by: byteOrder).compactMap { name in object[name].map { (name, $0) } }
    }

    private static func layoutVersion(_ node: SchemaJSON, key: String, path: String) throws(HotSchemaError) -> UInt8? {
        guard node[key]?.string == "binary" else { return nil }
        guard let raw = node["layout_version"]?.integer, let version = UInt8(exactly: raw), version >= 1 else {
            throw HotSchemaError(path: "\(path).layout_version", message: "a binary \(key) needs 1-255")
        }
        return version
    }

    private static func wireID(_ node: SchemaJSON, key: String, path: String) throws(HotSchemaError) -> UInt16 {
        guard let raw = node[key]?.integer, let id = UInt16(exactly: raw) else {
            throw HotSchemaError(path: "\(path).\(key)", message: "a binary layout needs a u16 \(key)")
        }
        return id
    }

    private mutating func body(_ expression: SchemaJSON, fallback: String, path: String) throws(HotSchemaError) -> String {
        var reached: [String] = []
        guard case .object(let name) = try wireType(expression, context: fallback, bounds: FieldBounds(), path: path, reached: &reached) else {
            throw HotSchemaError(path: path, message: "a binary body must be an object")
        }
        return name
    }

    private mutating func wireType(
        _ expression: SchemaJSON, context: String, bounds: FieldBounds, path: String, reached: inout [String]
    ) throws(HotSchemaError) -> WireType {
        switch expression["kind"]?.string ?? "" {
        case "ref":
            guard let name = expression["name"]?.string else { throw HotSchemaError(path: path, message: "a ref needs a name") }
            guard let target = types[name] else { throw HotSchemaError(path: path, message: "unknown type \"\(name)\"") }
            guard !reached.contains(name) else {
                throw HotSchemaError(path: path, message: "recursive type \"\(name)\" has no binary layout")
            }
            reached.append(name)
            defer { reached.removeLast() }
            return try wireType(target, context: name, bounds: bounds, path: "$.types.\(name)", reached: &reached)
        case "alias":
            guard let target = expression["target"] else { throw HotSchemaError(path: path, message: "an alias needs a target") }
            return try wireType(target, context: context, bounds: bounds, path: path, reached: &reached)
        case "scalar":
            return try Self.scalar(expression, bound: bounds.maxBytes, path: path)
        case "enum":
            return try enumeration(expression, name: context, path: path)
        case "object":
            return try object(expression, name: context, path: path, reached: &reached)
        case "array":
            // The field's bound is this array's; its items keep only the field's `max_bytes`.
            guard let raw = bounds.maxItems ?? expression["max_items"]?.integer, let maxItems = UInt16(exactly: raw) else {
                throw HotSchemaError(path: path, message: "a binary array needs max_items 0-65535")
            }
            guard let items = expression["items"] else { throw HotSchemaError(path: path, message: "no items") }
            let itemBounds = FieldBounds(maxBytes: bounds.maxBytes, maxItems: nil)
            let item = try wireType(items, context: context, bounds: itemBounds, path: "\(path).items", reached: &reached)
            return .array(items: item, maxItems: maxItems)
        case let other:
            throw HotSchemaError(path: path, message: "\"\(other)\" has no binary layout")
        }
    }

    private static func scalar(_ expression: SchemaJSON, bound: Int64?, path: String) throws(HotSchemaError) -> WireType {
        switch expression["name"]?.string ?? "" {
        case "boolean": return .bool
        case "uint16": return .u16
        case "uint32": return .u32
        case "uint64": return .u64
        case "int32": return .i32
        case "int64": return .i64
        case "float32": return .f32
        case "float64": return .f64
        case "string":
            guard let bound, bound >= 1, let maxBytes = UInt16(exactly: bound) else {
                throw HotSchemaError(path: path, message: "a binary string needs max_bytes 1-65535")
            }
            return .string(maxBytes: maxBytes)
        case let other:
            throw HotSchemaError(path: path, message: "scalar \"\(other)\" has no binary layout")
        }
    }

    private mutating func enumeration(_ expression: SchemaJSON, name: String, path: String) throws(HotSchemaError) -> WireType {
        var values: [String] = []
        if case .array(let items)? = expression["values"] {
            values = items.compactMap(\.string)
        }
        guard (1...256).contains(values.count) else {
            throw HotSchemaError(path: path, message: "a binary enum needs 1-256 string values")
        }
        let fallback = expression["fallback"]?.string
        if let fallback, !values.contains(fallback) {
            throw HotSchemaError(path: "\(path).fallback", message: "\(fallback) is not one of the values")
        }
        let entry = Enumeration(name: name, values: values, fallback: fallback)
        guard structs[name] == nil else { throw HotSchemaError(path: path, message: "\(name) names a struct and an enum") }
        if let known = enums[name], known != entry {
            throw HotSchemaError(path: path, message: "two enums are named \(name)")
        }
        enums[name] = entry
        return .enumeration(name)
    }

    private mutating func object(
        _ expression: SchemaJSON, name: String, path: String, reached: inout [String]
    ) throws(HotSchemaError) -> WireType {
        if expression["additional_properties"]?.bool == true {
            throw HotSchemaError(path: path, message: "a binary object cannot allow additional properties")
        }
        let declared = expression["fields"]?.object ?? [:]
        var fields: [Field] = []
        var literals: [Literal] = []
        for wire in declared.keys.sorted(by: Self.byteOrder) {
            guard let field = declared[wire] else { continue }
            let fieldPath = "\(path).fields.\(wire)"
            guard let typeExpression = field["type"] else { throw HotSchemaError(path: fieldPath, message: "a field needs a type") }
            if typeExpression["kind"]?.string == "literal" {
                literals.append(Literal(wire: wire, value: typeExpression["value"]?.string ?? ""))
                continue
            }
            let bounds = FieldBounds(maxBytes: field["max_bytes"]?.integer, maxItems: field["max_items"]?.integer)
            let fieldType = try wireType(typeExpression, context: name + Self.pascal(wire), bounds: bounds,
                                         path: fieldPath, reached: &reached)
            let required = field["presence"]?.string == "required"
            let nullable = field["nullable"]?.bool == true
            fields.append(Field(wire: wire, type: fieldType, tagged: !required || nullable, writesNull: required && nullable))
        }
        let swiftNames = (fields.map(\.wire) + literals.map(\.wire)).map(SwiftNaming.propertyName)
        if let clash = Dictionary(grouping: swiftNames, by: { $0 }).first(where: { $0.value.count > 1 })?.key {
            throw HotSchemaError(path: path, message: "two fields are \(clash) in Swift")
        }
        let entry = Struct(name: name, fields: fields, literals: literals)
        guard enums[name] == nil else { throw HotSchemaError(path: path, message: "\(name) names a struct and an enum") }
        if let known = structs[name], known != entry {
            throw HotSchemaError(path: path, message: "two structs are named \(name)")
        }
        structs[name] = entry
        return .object(name)
    }
}
