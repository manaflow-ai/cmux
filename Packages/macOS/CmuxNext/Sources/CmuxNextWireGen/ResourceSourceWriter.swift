/// Spells ResourceDeclarations as Swift source, four spaces per level. Every member is written
/// through `self.` and every coding key explicitly, so a field named like a local or a keyword
/// cannot change what the code means; there is no key strategy and no force unwrap.
struct ResourceSourceWriter {
    private(set) var lines: [String] = []

    mutating func line(_ text: String, _ indent: Int = 0) {
        lines.append(text.isEmpty ? "" : String(repeating: " ", count: indent * 4) + text)
    }

    mutating func write(_ declaration: ResourceDeclaration, _ indent: Int = 0) {
        switch declaration {
        case .object(let object): write(object, indent)
        case .openEnum(let name, let doc, let values): writeOpenEnum(name, doc: doc, values: values, indent)
        case .union(let union): write(union, indent)
        case .alias(let name, let doc, let target):
            for text in doc { line(text, indent) }
            line("public typealias \(name) = \(target)", indent)
        case .identifier(let name, let scope):
            line("/// A `\(scope)` resource id.", indent)
            line("public struct \(name): ResourceIdentifier {", indent)
            line("public static let scope = \(Self.literal(scope))", indent + 1)
            line("")
            line("public var rawValue: String", indent + 1)
            line("")
            line("public init(rawValue: String) {", indent + 1)
            line("self.rawValue = rawValue", indent + 2)
            line("}", indent + 1)
            line("}", indent)
        case .source(_, let text):
            for item in text { line(item, indent) }
        }
    }

    private mutating func write(_ object: ResourceDeclaration.Object, _ indent: Int) {
        for text in object.doc { line(text, indent) }
        line("public struct \(object.name)\(object.genericClause): \(object.conformances) {", indent)
        for text in object.header { line(text, indent + 1) }
        if !object.header.isEmpty { line("") }
        for field in object.fields {
            for text in field.doc { line(text, indent + 1) }
            line("public var \(field.member.spelling): \(field.declaredType)", indent + 1)
        }
        for nested in object.nested {
            line("")
            write(nested, indent + 1)
        }
        if !object.fields.isEmpty {
            line("")
            line("enum CodingKeys: String, CodingKey {", indent + 1)
            for field in object.fields {
                line("case \(field.member.spelling) = \(Self.literal(field.wireName))", indent + 2)
            }
            line("}", indent + 1)
        }
        line("")
        writeMemberwiseInit(object.fields, indent + 1)
        if object.decodes {
            line("")
            writeDecode(object.fields, indent + 1)
        }
        line("")
        writeEncode(object.fields, indent + 1)
        line("}", indent)
    }

    private mutating func writeMemberwiseInit(_ fields: [ResourceDeclaration.Field], _ indent: Int) {
        let parameters = fields.map { field in
            let defaultArgument = field.defaultArgument ?? Self.defaultArgument(field.presence)
            return "\(field.member.spelling): \(field.declaredType)" + (defaultArgument.map { " = \($0)" } ?? "")
        }
        guard !fields.isEmpty else {
            line("public init() {}", indent)
            return
        }
        line("public init(", indent)
        for (index, parameter) in parameters.enumerated() {
            line(parameter + (index == parameters.count - 1 ? "" : ","), indent + 1)
        }
        line(") {", indent)
        for field in fields {
            line("self.\(field.member.spelling) = \(field.member.spelling)", indent + 1)
        }
        line("}", indent)
    }

    /// The init parameter's default for a field without its own: nil for an optional field,
    /// `.unchanged` for an optional nullable one.
    private static func defaultArgument(_ presence: ResourceDeclaration.Presence) -> String? {
        switch presence {
        case .required, .requiredNullable: nil
        case .optional: "nil"
        case .optionalNullable: ".unchanged"
        }
    }

    private mutating func writeDecode(_ fields: [ResourceDeclaration.Field], _ indent: Int) {
        line("public init(from decoder: any Decoder) throws {", indent)
        if fields.isEmpty {
            // An empty object still has to be an object.
            line("_ = try decoder.container(keyedBy: ResourceCodingKey.self)", indent + 1)
        } else {
            line("let container = try decoder.container(keyedBy: CodingKeys.self)", indent + 1)
        }
        for field in fields {
            let member = field.member.spelling
            let value = switch field.presence {
            case .required: "container.decode(\(field.type).self, forKey: .\(member))"
            case .requiredNullable: "container.decode(\(field.type)?.self, forKey: .\(member))"
            case .optional: "container.decodeIfPresent(\(field.type).self, forKey: .\(member))"
            case .optionalNullable: "ResourceFieldUpdate(from: container, forKey: .\(member))"
            }
            line("self.\(member) = try \(value)", indent + 1)
        }
        line("}", indent)
    }

    private mutating func writeEncode(_ fields: [ResourceDeclaration.Field], _ indent: Int) {
        line("public func encode(to encoder: any Encoder) throws {", indent)
        if fields.isEmpty {
            line("_ = encoder.container(keyedBy: ResourceCodingKey.self)", indent + 1)
        } else {
            line("var container = encoder.container(keyedBy: CodingKeys.self)", indent + 1)
        }
        for field in fields {
            let member = field.member.spelling
            // A required nullable field writes `null`; an optional one is left out when nil; an
            // optional nullable one is left out, `null` or the value.
            switch field.presence {
            case .required, .requiredNullable:
                line("try container.encode(self.\(member), forKey: .\(member))", indent + 1)
            case .optional:
                line("try container.encodeIfPresent(self.\(member), forKey: .\(member))", indent + 1)
            case .optionalNullable:
                line("try self.\(member).encode(into: &container, forKey: .\(member))", indent + 1)
            }
        }
        line("}", indent)
    }

    private mutating func writeOpenEnum(_ name: String, doc: [String], values: [ResourceDeclaration.Value],
                                        _ indent: Int) {
        for text in doc { line(text, indent) }
        line("public struct \(name): RawRepresentable, Codable, Hashable, Sendable {", indent)
        for value in values {
            line("public static let \(value.member.spelling) = \(name)(rawValue: \(Self.literal(value.rawValue)))",
                 indent + 1)
        }
        line("")
        line("public var rawValue: String", indent + 1)
        line("")
        line("public init(rawValue: String) {", indent + 1)
        line("self.rawValue = rawValue", indent + 2)
        line("}", indent + 1)
        line("}", indent)
    }

    private mutating func write(_ union: ResourceDeclaration.Union, _ indent: Int) {
        for text in union.doc { line(text, indent) }
        line("public indirect enum \(union.name): Codable, Sendable, Equatable {", indent)
        for variant in union.variants {
            line("case \(variant.member.spelling)(\(variant.type))", indent + 1)
        }
        if union.keepsUnknown {
            line("/// A tag this build does not know, with the complete raw object.", indent + 1)
            line("case unknown(tag: String, raw: ResourceJSON)", indent + 1)
        }
        let discriminator = Self.literal(union.discriminator)
        line("")
        line("public init(from decoder: any Decoder) throws {", indent + 1)
        line("let tag = try ResourceCodingKey.discriminator(\(discriminator), in: decoder)", indent + 2)
        line("switch tag {", indent + 2)
        for variant in union.variants {
            let tags = variant.tags.map(Self.literal).joined(separator: ", ")
            line("case \(tags): self = .\(variant.member.spelling)(try \(variant.type)(from: decoder))", indent + 2)
        }
        if union.keepsUnknown {
            line("default: self = .unknown(tag: tag, raw: try ResourceJSON(from: decoder))", indent + 2)
        } else {
            line("default: throw ResourceCodingKey.unrecognized(tag, discriminator: \(discriminator), in: decoder)",
                 indent + 2)
        }
        line("}", indent + 2)
        line("}", indent + 1)
        line("")
        line("public func encode(to encoder: any Encoder) throws {", indent + 1)
        line("switch self {", indent + 2)
        for variant in union.variants {
            line("case .\(variant.member.spelling)(let value): try value.encode(to: encoder)", indent + 2)
        }
        if union.keepsUnknown {
            line("case .unknown(_, let raw): try raw.encode(to: encoder)", indent + 2)
        }
        line("}", indent + 2)
        line("}", indent + 1)
        line("}", indent)
    }

    /// A Swift string literal of `text`.
    static func literal(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += "\\u{" + String(scalar.value, radix: 16) + "}"
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}
