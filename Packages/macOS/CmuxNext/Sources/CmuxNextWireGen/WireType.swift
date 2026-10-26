/// A value type of a generated request or response, as the generated Swift spells it
/// (RequestSchema, RequestEmitter; p05-ipc task 021).
indirect enum WireType: Equatable {
    /// A type the target already has: a scalar, `Data`, a typed id or a named
    /// schema type (TypeEmitter's, task 020).
    case named(String)
    /// An `opaque_json` schema type, held as `JSONValue`.
    case json(schema: String)
    case array(WireType)
    case map(WireType)
    /// An inline object, emitted as a nested struct.
    case object(Object)
    /// An inline string enum, emitted as a nested enum.
    case enumeration(Enumeration)
    /// A constant: `swift` is its Swift literal, `base` the type it decodes as.
    case literal(swift: String, base: String)

    struct Object: Equatable {
        let name: String
        /// Required fields first, then optional ones, each by wire name.
        let fields: [Field]
    }

    struct Field: Equatable {
        let wire: String
        let swift: String
        let type: WireType
        let required: Bool
        let nullable: Bool
        let omitNil: Bool
        let defaultValue: SchemaJSON?
        let description: String?
    }

    struct Enumeration: Equatable {
        struct Case: Equatable {
            let swift: String
            let wire: String
        }

        let name: String
        let cases: [Case]
        /// The Swift case a decoder returns for a value it does not know.
        let fallback: String?
    }

    /// The Swift spelling of a value of this type.
    var swift: String {
        switch self {
        case .named(let name): name
        case .json: "JSONValue"
        case .array(let item): "[\(item.swift)]"
        case .map(let value): "[String: \(value.swift)]"
        case .object(let object): object.name
        case .enumeration(let enumeration): enumeration.name
        case .literal(_, let base): base
        }
    }

    /// Whether the generated file needs Foundation (for `Data`).
    var usesFoundation: Bool {
        switch self {
        case .named(let name): name == "Data"
        case .array(let item), .map(let item): item.usesFoundation
        case .object(let object): object.fields.contains { $0.type.usesFoundation }
        case .json, .enumeration, .literal: false
        }
    }

    /// The inline object or enum this type declares, through arrays and maps.
    var declared: WireType? {
        switch self {
        case .array(let item), .map(let item): item.declared
        case .object, .enumeration: self
        case .named, .json, .literal: nil
        }
    }
}
