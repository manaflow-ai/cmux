// TypeEmitter's untagged unions. The variants are named types,
// tried in schema order. An object variant is a candidate for a value when the
// value has every required member of it and every literal member it has holds
// the variant's constant (`dead: true`). A candidate that does not decode fails
// the value, unless a later candidate decodes it: a pane with a broken tab is a
// wire defect, not a pane this build does not know, as Mojo fails a message
// whose known union field does not validate
// (mojo/public/cpp/bindings/lib/validation_errors.h). Only a value no variant is
// a candidate for becomes `unknownVariant` (or an error, when the app only sends
// the union). A variant that is no object has no members to test: it is a
// candidate exactly when it decodes.

extension TypeEmitter {
    func untaggedUnionDeclaration(_ name: String, variants: [Schema.TypeExpr], scope: Scope) throws(TypeSchemaError) -> String {
        let body = scope.indent + "    "
        let statement = body + "    "
        var cases: [(member: String, type: String, test: String?)] = []
        for (index, variant) in variants.enumerated() {
            guard case .ref(let type) = variant else {
                throw TypeSchemaError(path: "\(scope.path).variants[\(index)]", message: "an untagged variant must be a named type")
            }
            let member = SwiftNames.caseName(ofType: type)
            guard !cases.contains(where: { $0.member == member }), !(scope.extensible && member == Self.unknownVariant) else {
                throw TypeSchemaError(path: "\(scope.path).variants[\(index)]", message: "its case name \(member) is taken")
            }
            cases.append((member, Self.swiftName(ofType: type), candidateTest(variant)))
        }
        let tested = cases.contains { $0.test != nil }
        var out = "\(scope.indent)public \(scope.recursive ? "indirect " : "")enum \(name): Codable, Sendable, Equatable {\n"
        for item in cases {
            out += "\(body)case \(item.member)(\(item.type))\n"
        }
        if scope.extensible {
            out += "\(body)/// A value no variant of this build is a candidate for, kept as written.\n"
            out += "\(body)case \(Self.unknownVariant)(\(Self.wireJSON))\n"
        }
        out += "\n\(body)/// The first candidate variant, in schema order, that decodes the value;\n"
        out += "\(body)/// when every candidate fails, the first one's error.\n"
        out += "\(body)public init(from decoder: any Decoder) throws {\n"
        if tested {
            out += "\(statement)let members = try? decoder.container(keyedBy: \(Self.anyKey).self)\n"
            out += "\(statement)var failure: (any Error)?\n"
        }
        for item in cases {
            guard let test = item.test else {
                out += "\(statement)if let value = try? \(item.type)(from: decoder) {\n"
                out += "\(statement)    self = .\(item.member)(value)\n\(statement)    return\n\(statement)}\n"
                continue
            }
            out += "\(statement)if \(test) {\n"
            out += "\(statement)    do {\n"
            out += "\(statement)        self = .\(item.member)(try \(item.type)(from: decoder))\n"
            out += "\(statement)        return\n"
            out += "\(statement)    } catch {\n"
            out += "\(statement)        failure = failure ?? error\n"
            out += "\(statement)    }\n"
            out += "\(statement)}\n"
        }
        if tested {
            out += "\(statement)if let failure { throw failure }\n"
        }
        if scope.extensible {
            out += "\(statement)self = .\(Self.unknownVariant)(try \(Self.wireJSON)(from: decoder))\n"
        } else {
            out += "\(statement)throw DecodingError.dataCorrupted(DecodingError.Context(\n"
            out += "\(statement)    codingPath: decoder.codingPath, debugDescription: \"no \(name) variant matches this value\"))\n"
        }
        out += "\(body)}\n\n"
        out += "\(body)public func encode(to encoder: any Encoder) throws {\n\(statement)switch self {\n"
        for item in cases {
            out += "\(statement)case .\(item.member)(let value): try value.encode(to: encoder)\n"
        }
        if scope.extensible {
            out += "\(statement)case .\(Self.unknownVariant)(let json): try json.encode(to: encoder)\n"
        }
        out += "\(statement)}\n\(body)}\n"
        return out + "\(scope.indent)}\n"
    }

    /// The `if` condition under which the object variant `variant` is a candidate
    /// (`members` is the value's keyed container, nil when it is no object); nil
    /// when the variant is no object.
    private func candidateTest(_ variant: Schema.TypeExpr) -> String? {
        guard case .object(let object) = resolved(variant) else { return nil }
        var conditions: [String] = []
        for field in object.fields {
            let names = ([field.name] + field.aliases).map(SwiftNames.literal).joined(separator: ", ")
            if field.required {
                conditions.append("members.wireHas(\(names))")
            }
            if case .literal(let value) = field.type {
                conditions.append("members.wireLiteralHolds(\(Self.constant(value)), \(names))")
            }
        }
        return conditions.isEmpty ? "members != nil" : (["let members"] + conditions).joined(separator: ", ")
    }
}
