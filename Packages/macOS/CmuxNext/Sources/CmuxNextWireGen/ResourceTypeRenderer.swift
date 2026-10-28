/// Turns catalog type expressions into Swift types and the declarations they need.
///
/// Primitives: `string`, `decimal` (a decimal string) and `base64` are `String`; `json` is
/// `ResourceJSON`; the integer and float names map to the same-width Swift types. `resource_id`
/// is the scope's typed id, `selector` is `ResourceSelector`. An inline enum, object or tagged
/// union becomes a nested type named after its field (`Element` and `Value` appended inside an
/// array or a map). A union without a discriminator has no tag to switch on (the enclosing value
/// selects the variant, per its constraints): one of ids or strings is `String`, any other is
/// `ResourceJSON`, so decoding never guesses a variant by trying each in turn.
struct ResourceTypeRenderer {
    let catalog: ResourceCatalog

    static let objectConformances = "Codable, Sendable, Equatable"
    /// What a generic's parameter must be for the generic to have `objectConformances`.
    static let parameterConstraint = "Codable & Sendable & Equatable"
    private static let primitives = [
        "string": "String", "decimal": "String", "base64": "String", "json": "ResourceJSON", "boolean": "Bool",
        "uint16": "UInt16", "uint32": "UInt32", "uint64": "UInt64", "int32": "Int32", "float64": "Double",
    ]

    /// The declarations of named type `name` (`$.types.<name>`): its own, plus top-level types its
    /// alias needs (an alias has no body to nest them in).
    func declarations(named name: String) throws(ResourceEmitterError) -> [ResourceDeclaration] {
        let path = "$.types.\(name)"
        let swiftName = ResourceSwiftName.type(name)
        let doc = ["/// `\(name)` (resource-operations-v2.json)."]
        guard let expr = catalog.types[name] else {
            guard let generic = catalog.generics[name] else { throw .unknownType(name) }
            return [try genericDeclaration(swiftName, generic: generic, path: "$.generics.\(name)", doc: doc)]
        }
        switch expr {
        case .object(let fields):
            return [.object(try object(swiftName, fields: fields, path: path, doc: doc))]
        case .enumeration(let values):
            return [try openEnum(swiftName, values: values, path: path, doc: doc)]
        default:
            var nested: [ResourceDeclaration] = []
            let target = try swiftType(expr, hint: swiftName, path: path, nested: &nested)
            // A tagged union rendered under its own name is the declaration itself.
            if target == swiftName { return nested }
            return [.alias(name: swiftName, doc: doc, target: target)] + nested
        }
    }

    /// The Swift type of `expr`; inline declarations it needs are appended to `nested`, named
    /// `hint` (a Swift identifier the caller chose).
    func swiftType(_ expr: ResourceTypeExpr, hint: String, path: String, generics: Set<String> = [],
                   nested: inout [ResourceDeclaration]) throws(ResourceEmitterError) -> String {
        switch expr {
        case .primitive(let name):
            guard let type = Self.primitives[name] else {
                throw .unsupported(path: path, reason: "unknown primitive \(name)")
            }
            return type
        case .resourceID(let scope):
            try checkScope(scope, path: path)
            return try ResourceSwiftName.identifier(scope: scope, path: path)
        case .selector(let scope):
            try checkScope(scope, path: path)
            return "ResourceSelector"
        case .ref(let name):
            if catalog.types[name] != nil { return ResourceSwiftName.type(name) }
            if catalog.generics[name] != nil { throw .unsupported(path: path, reason: "generic \(name) needs arguments") }
            throw .unknownType(name)
        case .parameter(let name):
            guard generics.contains(name) else { throw .unsupported(path: path, reason: "\(name) is not a parameter here") }
            return name
        case .apply(let name, let arguments):
            guard let generic = catalog.generics[name] else { throw .unknownType(name) }
            guard generic.parameters.count == arguments.count else {
                throw .unsupported(path: path, reason: "\(name) takes \(generic.parameters.count) arguments")
            }
            var rendered: [String] = []
            for (index, argument) in arguments.enumerated() {
                let argumentHint = hint + "Value" + (arguments.count == 1 ? "" : "\(index)")
                rendered.append(try swiftType(argument, hint: argumentHint, path: path + ".arguments[\(index)]",
                                              generics: generics, nested: &nested))
            }
            return ResourceSwiftName.type(name) + "<" + rendered.joined(separator: ", ") + ">"
        case .enumeration(let values):
            // A static stored property cannot live in a generic type, nested or not.
            guard generics.isEmpty else { throw .unsupported(path: path, reason: "inline enum in a generic") }
            nested.append(try openEnum(hint, values: values, path: path, doc: []))
            return hint
        case .array(let items):
            let element = try swiftType(items, hint: hint + "Element", path: path + ".items", generics: generics, nested: &nested)
            return "[\(element)]"
        case .map(let values):
            let value = try swiftType(values, hint: hint + "Value", path: path + ".values", generics: generics, nested: &nested)
            return "[String: \(value)]"
        case .nullable(let value):
            let type = try swiftType(value, hint: hint, path: path + ".value", generics: generics, nested: &nested)
            return type.hasSuffix("?") ? type : type + "?"
        case .union(let variants, let discriminator, let keepsUnknown):
            guard let discriminator else {
                return variants.allSatisfy(Self.isString) ? "String" : "ResourceJSON"
            }
            nested.append(.union(try union(hint, variants: variants, discriminator: discriminator,
                                           keepsUnknown: keepsUnknown, path: path)))
            return hint
        case .object(let fields):
            nested.append(.object(try object(hint, fields: fields, path: path, generics: generics, doc: [])))
            return hint
        }
    }

    /// An object's declaration: fields in wire-name order, inline shapes nested.
    func object(_ name: String, fields: [String: ResourceCatalog.Field], path: String,
                generics: Set<String> = [], doc: [String]) throws(ResourceEmitterError) -> ResourceDeclaration.Object {
        var nested: [ResourceDeclaration] = []
        var declared: [ResourceDeclaration.Field] = []
        for wireName in fields.keys.sorted() {
            guard let field = fields[wireName] else { continue }
            declared.append(try self.field(wireName, field, path: path + ".fields.\(wireName)",
                                           generics: generics, nested: &nested))
        }
        try Self.checkUnique(declared.map(\.member.spelling), path: path)
        try Self.checkUnique(nested.map(\.name), path: path)
        return ResourceDeclaration.Object(name: name, conformances: Self.objectConformances, doc: doc,
                                          fields: declared, nested: nested)
    }

    /// One field: its member, its type with nullability lifted into presence.
    func field(_ wireName: String, _ field: ResourceCatalog.Field, path: String, generics: Set<String> = [],
               nested: inout [ResourceDeclaration]) throws(ResourceEmitterError) -> ResourceDeclaration.Field {
        let hint = try ResourceSwiftName.nestedType(wireName, path: path)
        var type = try swiftType(field.type, hint: hint, path: path + ".type", generics: generics, nested: &nested)
        let nullable = type.hasSuffix("?")
        if nullable { type.removeLast() }
        let presence: ResourceDeclaration.Presence =
            !field.required ? .optional : nullable ? .requiredNullable : .required
        return ResourceDeclaration.Field(member: try ResourceSwiftName.member(wireName, path: path), wireName: wireName,
                                         type: type, presence: presence, defaultArgument: nil,
                                         doc: Self.doc(field.description))
    }

    func openEnum(_ name: String, values: [String], path: String,
                  doc: [String]) throws(ResourceEmitterError) -> ResourceDeclaration {
        var members: [ResourceDeclaration.Value] = []
        for value in values {
            members.append(.init(member: try ResourceSwiftName.member(value, path: path + ".values"), rawValue: value))
        }
        try Self.checkUnique(members.map(\.member.spelling), path: path + ".values")
        return .openEnum(name: name, doc: doc, values: members)
    }

    /// `///` lines of a catalog description.
    static func doc(_ text: String?) -> [String] {
        guard let text else { return [] }
        return text.split(separator: "\n", omittingEmptySubsequences: false).map { $0.isEmpty ? "///" : "/// \($0)" }
    }

    static func checkUnique(_ names: [String], path: String) throws(ResourceEmitterError) {
        var seen = Set<String>()
        for name in names where !seen.insert(name).inserted {
            throw .nameCollision(path: path, swiftName: name)
        }
    }

    private static func isString(_ expr: ResourceTypeExpr) -> Bool {
        switch expr {
        case .resourceID: true
        case .primitive(let name): name == "string"
        default: false
        }
    }

    private func checkScope(_ scope: String, path: String) throws(ResourceEmitterError) {
        guard catalog.resourceScopes.contains(scope) else {
            throw .unsupported(path: path, reason: "\(scope) is not a resource scope")
        }
    }

    private func genericDeclaration(_ name: String, generic: ResourceCatalog.Generic, path: String,
                                    doc: [String]) throws(ResourceEmitterError) -> ResourceDeclaration {
        guard case .object(let fields) = generic.body else {
            throw .unsupported(path: path, reason: "a generic body must be an object")
        }
        var declaration = try object(name, fields: fields, path: path + ".body", generics: Set(generic.parameters), doc: doc)
        let parameters = generic.parameters.map { "\($0): \(Self.parameterConstraint)" }
        declaration.genericClause = "<" + parameters.joined(separator: ", ") + ">"
        return .object(declaration)
    }

    /// A tagged union: every variant names an object whose discriminator field is an enum of the
    /// tags that select it.
    private func union(_ name: String, variants: [ResourceTypeExpr], discriminator: String, keepsUnknown: Bool,
                       path: String) throws(ResourceEmitterError) -> ResourceDeclaration.Union {
        var cases: [ResourceDeclaration.Variant] = []
        for (index, variant) in variants.enumerated() {
            let variantPath = path + ".variants[\(index)]"
            guard case .ref(let typeName) = variant, case .object(let fields)? = catalog.types[typeName],
                  let tag = fields[discriminator], tag.required, case .enumeration(let tags) = tag.type, let first = tags.first
            else {
                throw .unsupported(path: variantPath, reason: "a tagged variant must name an object whose required "
                    + "\(discriminator) is an enum of its tags")
            }
            cases.append(.init(member: try ResourceSwiftName.member(first, path: variantPath), tags: tags,
                               type: ResourceSwiftName.type(typeName)))
        }
        try Self.checkUnique(cases.map(\.member.spelling) + (keepsUnknown ? ["unknown"] : []), path: path)
        try Self.checkUnique(cases.flatMap(\.tags), path: path)
        return ResourceDeclaration.Union(name: name, doc: [], discriminator: discriminator, variants: cases,
                                         keepsUnknown: keepsUnknown)
    }
}

extension ResourceDeclaration {
    /// The declared type's name.
    var name: String {
        switch self {
        case .object(let object): object.name
        case .openEnum(let name, _, _), .alias(let name, _, _), .identifier(let name, _), .source(let name, _): name
        case .union(let union): union.name
        }
    }
}
