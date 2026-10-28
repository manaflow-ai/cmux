// TypeEmitter's object types: a public struct with explicit CodingKeys and a
// written-out init(from:) and encode(to:). Presence rules:
//
//   required              `T` (`T?` when nullable, nil written as null)
//   optional, default     `T` (`T?` when nullable) starting at the default; absent
//                         decodes as the default and the default is not written,
//                         so a daemon older than the member never sees it
//   optional, no default  `T?`; nil is not written (`omit_nil` always holds)
//   literal               no property: a required one is written as its constant;
//                         a present one must equal it (untagged unions rely on that)

extension TypeEmitter {
    /// One member of a struct as the emitter writes it.
    struct Member {
        let field: Schema.Field
        /// The Swift property and CodingKeys case, escaped.
        let property: String
        /// The CodingKeys cases of the member's aliases, in schema order.
        let aliasKeys: [String]
        /// The property's type without the optional of a nullable or absent member.
        let baseType: String
        let isOptional: Bool
        let literal: SchemaJSON?
        /// The Swift expression of a non-null default.
        let defaultValue: String?

        var declaredType: String { isOptional ? baseType + "?" : baseType }

        /// The key to decode: the first of the member's wire names that is present.
        var decodeKey: String {
            guard !aliasKeys.isEmpty else { return ".\(property)" }
            return "container.wireKey(\(([property] + aliasKeys).map { "." + $0 }.joined(separator: ", ")))"
        }
    }

    func structDeclaration(_ name: String, object: Schema.Object, scope: Scope) throws(TypeSchemaError) -> String {
        let inner = scope.nested(scope.path, in: name)
        let body = inner.indent
        let statement = body + "    "
        var nested: [String] = []
        var taken: Set<String> = []
        var members: [Member] = []
        var keys: Set<String> = []
        for field in object.fields {
            let path = "\(scope.path).fields.\(field.name)"
            let member = try self.member(field, path: path, scope: inner, nested: &nested, taken: &taken)
            for key in [member.property] + member.aliasKeys where !keys.insert(key).inserted {
                throw TypeSchemaError(path: path, message: "its Swift name \(key) is also another member's")
            }
            members.append(member)
        }
        let stored = members.filter { $0.literal == nil }
        let keyType = members.isEmpty ? Self.anyKey : "CodingKeys"

        var out = "\(scope.indent)public struct \(name): Codable, Sendable, Equatable {\n"
        for member in stored {
            out += SwiftNames.doc(member.field.summary, indent: body)
            out += "\(body)public var \(member.property): \(member.declaredType)\n"
        }
        if !stored.isEmpty { out += "\n" }
        let parameters = stored.map { member in
            let fallback = member.defaultValue ?? (member.field.required ? nil : "nil")
            return "\(member.property): \(member.declaredType)" + (fallback.map { " = \($0)" } ?? "")
        }
        if stored.isEmpty {
            out += "\(body)public init() {}\n\n"
        } else {
            out += "\(body)public init(\(parameters.joined(separator: ", "))) {\n"
            for member in stored {
                out += "\(statement)self.\(member.property) = \(member.property)\n"
            }
            out += "\(body)}\n\n"
        }
        if !members.isEmpty {
            out += "\(body)enum CodingKeys: String, CodingKey {\n"
            for member in members {
                out += "\(statement)case \(member.property) = \(SwiftNames.literal(member.field.name))\n"
                for (alias, wire) in zip(member.aliasKeys, member.field.aliases) {
                    out += "\(statement)case \(alias) = \(SwiftNames.literal(wire))\n"
                }
            }
            out += "\(body)}\n\n"
        }
        out += "\(body)public init(from decoder: any Decoder) throws {\n"
        out += "\(statement)\(members.isEmpty ? "_" : "let container") = try decoder.container(keyedBy: \(keyType).self)\n"
        for member in members {
            out += statement + decodeStatement(member) + "\n"
        }
        out += "\(body)}\n\n"
        let encodes = members.compactMap(encodeStatement)
        out += "\(body)public func encode(to encoder: any Encoder) throws {\n"
        out += "\(statement)\(encodes.isEmpty ? "_" : "var container") = encoder.container(keyedBy: \(keyType).self)\n"
        for line in encodes {
            out += statement + line + "\n"
        }
        out += "\(body)}\n"
        for declaration in nested {
            out += "\n" + declaration
        }
        return out + "\(scope.indent)}\n"
    }

    private func member(
        _ field: Schema.Field,
        path: String,
        scope: Scope,
        nested: inout [String],
        taken: inout Set<String>
    ) throws(TypeSchemaError) -> Member {
        let names = SwiftNames(field.name)
        let property = names.escapedMember
        let aliasKeys = field.aliases.indices.map { SwiftNames.escaped(names.member + "Alias\($0)") }
        if case .literal(let value) = field.type {
            return Member(field: field, property: property, aliasKeys: aliasKeys, baseType: "",
                          isOptional: false, literal: value, defaultValue: nil)
        }
        let memberScope = scope.at(path)
        let baseType = try swiftType(field.type, member: field.name, nestAs: names.type, scope: memberScope,
                                     nested: &nested, taken: &taken)
        var defaultValue: String?
        if let value = field.defaultValue, value != .null {
            defaultValue = try defaultExpression(value, field: field, typeName: baseType, scope: memberScope, path: path)
            if field.omitNil, field.nullable {
                throw TypeSchemaError(path: "\(path).omit_nil", message: "absent means the default, so nil must be written as null")
            }
        }
        let isOptional = field.nullable || (!field.required && defaultValue == nil)
        return Member(field: field, property: property, aliasKeys: aliasKeys, baseType: baseType,
                      isOptional: isOptional, literal: nil, defaultValue: defaultValue)
    }

    private func decodeStatement(_ member: Member) -> String {
        let key = member.decodeKey
        if let literal = member.literal {
            return "try container.wireLiteral(\(Self.constant(literal)), forKey: \(key), required: \(member.field.required))"
        }
        let value: String
        switch (member.field.required, member.defaultValue) {
        case (true, _):
            // `T?.self` for a nullable member: the key must be there, its value may be null.
            value = "try container.decode(\(member.declaredType).self, forKey: \(key))"
        case (false, let fallback?) where member.field.nullable:
            value = "try container.contains(\(key)) ? container.decode(\(member.declaredType).self, forKey: \(key)) : \(fallback)"
        case (false, let fallback?):
            value = "try container.decodeIfPresent(\(member.baseType).self, forKey: \(key)) ?? \(fallback)"
        case (false, nil):
            value = "try container.decodeIfPresent(\(member.baseType).self, forKey: \(key))"
        }
        return "self.\(member.property) = \(value)"
    }

    private func encodeStatement(_ member: Member) -> String? {
        let key = ".\(member.property)"
        if let literal = member.literal {
            return member.field.required ? "try container.encode(\(Self.constant(literal)), forKey: \(key))" : nil
        }
        let value = "self.\(member.property)"
        if member.field.required {
            return "try container.encode(\(value), forKey: \(key))"
        }
        guard let fallback = member.defaultValue else {
            return "try container.encodeIfPresent(\(value), forKey: \(key))"
        }
        return "if \(value) != \(fallback) { try container.encode(\(value), forKey: \(key)) }"
    }

    /// A literal member's constant as a Swift literal.
    static func constant(_ value: SchemaJSON) -> String {
        switch value {
        case .bool(let flag): String(flag)
        case .integer(let number): "Int64(\(number))"
        case .string(let text): SwiftNames.literal(text)
        default: "nil"
        }
    }
}
