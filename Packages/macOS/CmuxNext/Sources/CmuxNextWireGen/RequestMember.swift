/// One member of a generated request or response: its Swift property and how the
/// generated coder writes or reads it (RequestEmitter, p05-ipc task 021).
///
/// A request writes what it holds: a nil optional is left out, so a line carries
/// only the members the caller set (the daemon applies the schema's defaults); a
/// required nullable member writes `null`. A response reads the schema's `default`
/// for an absent optional member when that default has a Swift literal.
struct RequestMember {
    static let integerTypes: Set = ["Int32", "UInt16", "UInt32", "Int64", "UInt64"]

    let field: WireType.Field
    let role: RequestEmitter.Role

    /// The property and parameter name.
    var name: String { SwiftNaming.identifier(field.swift) }

    /// The CodingKeys case this member is coded under, with its leading dot.
    var key: String { ".\(name)" }

    /// The constant of a literal member.
    var literal: (swift: String, base: String)? {
        guard case .literal(let swift, let base) = field.type else { return nil }
        return (swift: swift, base: base)
    }

    /// Whether the type has a property for it: a request writes its constants without one.
    var isStored: Bool { role == .decodable || literal == nil }

    /// The Swift literal of the schema's default, where a decoded absent member takes it.
    var defaultLiteral: String? {
        guard role == .decodable, !field.required, !field.nullable else { return nil }
        switch (field.defaultValue, field.type) {
        case (.bool(let value)?, .named("Bool")):
            return "\(value)"
        case (.integer(let value)?, .named(let type)) where Self.integerTypes.contains(type) && value >= 0:
            return "\(value)"
        case (.integer(let value)?, .named("Float")), (.integer(let value)?, .named("Double")):
            return "\(value)"
        case (.number(let value)?, .named("Float")), (.number(let value)?, .named("Double")):
            return "\(value)"
        case (.string(let value)?, .named("String")):
            return TableEmitter.literal(value)
        case (.string(let value)?, .enumeration(let enumeration)):
            return enumeration.cases.first { $0.wire == value }.map { ".\(SwiftNaming.identifier($0.swift))" }
        case (.array(let items)?, .array) where items.isEmpty:
            return "[]"
        case (.object(let members)?, .map) where members.isEmpty:
            return "[:]"
        default:
            return nil
        }
    }

    var isOptional: Bool {
        guard literal == nil else { return false }
        if field.required { return field.nullable }
        return defaultLiteral == nil
    }

    var propertyType: String { field.type.swift + (isOptional ? "?" : "") }

    /// The init parameter's default: nil for an optional member, its constant or schema
    /// default otherwise; a required member, nullable or not, has none.
    var parameterDefault: String? {
        if let literal { return literal.swift }
        if field.required { return nil }
        return isOptional ? "nil" : defaultLiteral
    }

    /// The statement of `encode(to:)`.
    var encodeStatement: String {
        if let literal { return "try container.encode(\(literal.swift) as \(literal.base), forKey: \(key))" }
        // A required nullable member writes `null` for nil (Optional encodes as null); an
        // optional one, or one marked omit_nil, leaves the key out.
        if isOptional && (!field.required || field.omitNil) {
            return "try container.encodeIfPresent(self.\(name), forKey: \(key))"
        }
        return "try container.encode(self.\(name), forKey: \(key))"
    }

    /// The statements of `init(from:)`.
    var decodeStatements: [String] {
        let type = field.type.swift
        if let literal {
            // An optional constant that is absent reads as the constant.
            let read = field.required
                ? "try container.decode(\(literal.base).self, forKey: \(key))"
                : "try container.decodeIfPresent(\(literal.base).self, forKey: \(key)) ?? \(literal.swift)"
            return [
                "do {",
                "    let value = \(read)",
                "    guard value == \(literal.swift) else {",
                "        throw DecodingError.dataCorruptedError(forKey: \(key), in: container,",
                "                                               debugDescription: \"not the schema's constant\")",
                "    }",
                "    self.\(name) = value",
                "}",
            ]
        }
        if field.required {
            // A nullable required member must be present; `null` is nil.
            let decoded = field.nullable ? "Optional<\(type)>" : type
            return ["self.\(name) = try container.decode(\(decoded).self, forKey: \(key))"]
        }
        let fallback = defaultLiteral.map { " ?? \($0)" } ?? ""
        return ["self.\(name) = try container.decodeIfPresent(\(type).self, forKey: \(key))\(fallback)"]
    }
}
