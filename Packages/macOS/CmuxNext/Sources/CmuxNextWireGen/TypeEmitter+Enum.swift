// TypeEmitter's enums and unions.
//
// An enum the app only sends is a closed String enum. One it decodes is
// extensible, as Mojo's [Extensible] enums are: with a schema `fallback` an
// unknown string decodes as that value (Mojo's [Default]); without one it is
// `unknown(String)`, which also holds a schema value literally named
// "unknown". A tagged union is an enum with one case per variant struct (the
// struct writes and checks its tag member); a decoded one keeps an unknown tag
// as `unknownVariant(tag:json:)` (a variant may itself be named "unknown").
// Untagged unions are TypeEmitter+UntaggedUnion.swift.

extension TypeEmitter {
    /// The case a decoded union keeps a value of no known variant in.
    static let unknownVariant = "unknownVariant"

    /// The Swift expression of enum value `value`.
    static func enumCase(_ value: String, of enumeration: Schema.Enumeration, extensible: Bool) -> String {
        if catchesUnknown(enumeration, extensible: extensible), SwiftNames(value).member == "unknown" {
            return ".unknown(\(SwiftNames.literal(value)))"
        }
        return "." + SwiftNames(value).escapedMember
    }

    private static func catchesUnknown(_ enumeration: Schema.Enumeration, extensible: Bool) -> Bool {
        extensible && enumeration.fallback == nil
    }

    func enumDeclaration(_ name: String, enumeration: Schema.Enumeration, scope: Scope) throws(TypeSchemaError) -> String {
        let body = scope.indent + "    "
        let statement = body + "    "
        var seen: [String: String] = [:]
        for value in enumeration.values {
            let member = SwiftNames(value).member
            if let other = seen.updateValue(value, forKey: member) {
                throw TypeSchemaError(path: "\(scope.path).values", message: "\(value) and \(other) are both case \(member)")
            }
        }
        guard scope.extensible else {
            var out = "\(scope.indent)public enum \(name): String, Codable, Sendable, Equatable, Hashable, CaseIterable {\n"
            for value in enumeration.values {
                out += "\(body)case \(SwiftNames(value).escapedMember) = \(SwiftNames.literal(value))\n"
            }
            return out + "\(scope.indent)}\n"
        }
        let catchAll = Self.catchesUnknown(enumeration, extensible: true)
        let known = enumeration.values.filter { !catchAll || SwiftNames($0).member != "unknown" }
        var out = "\(scope.indent)public enum \(name): RawRepresentable, Codable, Sendable, Equatable, Hashable {\n"
        for value in known {
            out += "\(body)case \(SwiftNames(value).escapedMember)\n"
        }
        if catchAll {
            out += "\(body)/// A value this build does not know, kept as written.\n"
            out += "\(body)case unknown(String)\n"
        }
        out += "\n\(body)public init(rawValue: String) {\n\(statement)switch rawValue {\n"
        for value in known {
            out += "\(statement)case \(SwiftNames.literal(value)): self = .\(SwiftNames(value).escapedMember)\n"
        }
        let unknown = enumeration.fallback.map { Self.enumCase($0, of: enumeration, extensible: true) } ?? ".unknown(rawValue)"
        out += "\(statement)default: self = \(unknown)\n\(statement)}\n\(body)}\n\n"
        out += "\(body)public var rawValue: String {\n\(statement)switch self {\n"
        for value in known {
            out += "\(statement)case .\(SwiftNames(value).escapedMember): \(SwiftNames.literal(value))\n"
        }
        if catchAll {
            out += "\(statement)case .unknown(let value): value\n"
        }
        out += "\(statement)}\n\(body)}\n\n"
        out += "\(body)public init(from decoder: any Decoder) throws {\n"
        out += "\(statement)self.init(rawValue: try decoder.singleValueContainer().decode(String.self))\n\(body)}\n\n"
        out += "\(body)public func encode(to encoder: any Encoder) throws {\n"
        out += "\(statement)var container = encoder.singleValueContainer()\n"
        out += "\(statement)try container.encode(rawValue)\n\(body)}\n"
        return out + "\(scope.indent)}\n"
    }

    func taggedUnionDeclaration(_ name: String, union: Schema.TaggedUnion, scope: Scope) throws(TypeSchemaError) -> String {
        let inner = scope.nested(scope.path, in: name)
        let body = inner.indent
        let statement = body + "    "
        var taken: Set<String> = []
        var cases: [(tag: String, member: String, type: String)] = []
        var nested: [String] = []
        var seen: Set<String> = []
        for variant in union.variants {
            let member = SwiftNames(variant.tag).escapedMember
            guard seen.insert(member).inserted, !(scope.extensible && member == Self.unknownVariant) else {
                throw TypeSchemaError(path: "\(scope.path).variants.\(variant.tag)", message: "its case name \(member) is taken")
            }
            let type = freeTypeName(SwiftNames(variant.tag).type, scope: inner, taken: &taken)
            nested.append(try structDeclaration(type, object: variant.object, scope: inner.at("\(scope.path).variants.\(variant.tag)")))
            cases.append((variant.tag, member, type))
        }
        var out = "\(scope.indent)public \(scope.recursive ? "indirect " : "")enum \(name): Codable, Sendable, Equatable {\n"
        for item in cases {
            out += "\(body)case \(item.member)(\(item.type))\n"
        }
        if scope.extensible {
            out += "\(body)/// A variant this build does not know, kept as written.\n"
            out += "\(body)case \(Self.unknownVariant)(tag: String, json: \(Self.wireJSON))\n"
        }
        out += "\n\(body)private enum TagKey: String, CodingKey {\n\(statement)case tag = \(SwiftNames.literal(union.tagField))\n\(body)}\n\n"
        out += "\(body)public init(from decoder: any Decoder) throws {\n"
        out += "\(statement)let tag = try decoder.container(keyedBy: TagKey.self).decode(String.self, forKey: .tag)\n"
        out += "\(statement)switch tag {\n"
        for item in cases {
            out += "\(statement)case \(SwiftNames.literal(item.tag)): self = .\(item.member)(try \(item.type)(from: decoder))\n"
        }
        if scope.extensible {
            out += "\(statement)default: self = .\(Self.unknownVariant)(tag: tag, json: try \(Self.wireJSON)(from: decoder))\n"
        } else {
            out += "\(statement)default:\n"
            out += "\(statement)    throw DecodingError.dataCorrupted(DecodingError.Context(\n"
            out += "\(statement)        codingPath: decoder.codingPath, debugDescription: \"unknown \(name) tag \\(tag)\"))\n"
        }
        out += "\(statement)}\n\(body)}\n\n"
        out += "\(body)public func encode(to encoder: any Encoder) throws {\n\(statement)switch self {\n"
        for item in cases {
            out += "\(statement)case .\(item.member)(let value): try value.encode(to: encoder)\n"
        }
        if scope.extensible {
            out += "\(statement)case .\(Self.unknownVariant)(_, let json): try json.encode(to: encoder)\n"
        }
        out += "\(statement)}\n\(body)}\n"
        for declaration in nested {
            out += "\n" + declaration
        }
        return out + "\(scope.indent)}\n"
    }
}
