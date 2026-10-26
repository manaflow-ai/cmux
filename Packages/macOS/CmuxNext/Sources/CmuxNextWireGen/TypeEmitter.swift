import Foundation

// Writes the Swift wire types the app's commands reach (p05-ipc-020; design
// plans/cmux-next/chrome-parity/p05-ipc.md section 3.3) at build time, from
// cmux-tui/spec/sdk-schema.json. Requests and responses (021), events (022)
// and v2 operations (024) are written by their own emitters over the same
// TypeSchema with `swiftType` and `structDeclaration`.
//
// Chromium's mojom bindings generator is the model
// (mojo/public/tools/bindings/generators/mojom_cpp_generator.py): one value
// type per schema struct, union and enum, each member with its explicit wire
// name, and an [Extensible] enum keeps a value it does not know instead of
// failing the message (mojo/public/cpp/bindings/enum_traits.h). Here every
// enum and tagged union the app decodes from a reply is extensible; one the
// app only sends stays closed. The output is a pure function of the schema bytes.

/// One generated Swift source file.
struct GeneratedSource: Equatable {
    let fileName: String
    let text: String
}

struct TypeEmitter {
    typealias Schema = TypeSchema

    /// Where a declaration is written: the JSON path for errors, its indent, the
    /// names it must not shadow, and how its inline types are shaped.
    struct Scope {
        let path: String
        let indent: String
        /// The enclosing type names, outermost first: a nested type never takes one.
        let enclosing: [String]
        /// The app decodes this type: enums and unions keep values they do not know.
        let extensible: Bool
        /// The named type holds itself through a union, so its unions are `indirect`.
        let recursive: Bool

        /// The scope of the declarations inside type `name`.
        func nested(_ path: String, in name: String) -> Scope {
            Scope(path: path, indent: indent + "    ", enclosing: enclosing + [name],
                  extensible: extensible, recursive: recursive)
        }

        /// The same place, for errors about `path`.
        func at(_ path: String) -> Scope {
            Scope(path: path, indent: indent, enclosing: enclosing, extensible: extensible, recursive: recursive)
        }
    }

    /// The hand-written declarations of CmuxNextIPC, the module the output compiles into.
    static let hostTypeNames: Set<String> = [
        "BadMessage", "EventAttributes", "EventID", "Frame", "FrameHeader", "FrameReader", "MethodAttributes",
        "MethodCoalesce", "MethodDurability", "MethodID", "MethodOrdering", "MethodPayload", "MethodPriority",
        "MethodTable", "MethodTableFamily", "WireSchemaIdentity",
    ]

    /// Standard library names the generated code spells; no generated type may shadow one.
    static let standardTypeNames: Set<String> = [
        "Any", "Array", "Bool", "CodingKey", "CodingKeys", "Codable", "Decodable", "Decoder", "DecodingError",
        "Dictionary", "Double", "Encodable", "Encoder", "EncodingError", "Equatable", "Error", "Float", "Hashable",
        "Int", "Int32", "Int64", "Never", "Optional", "Protocol", "RawRepresentable", "Self", "Sendable", "String",
        "Swift", "Type", "UInt16", "UInt32", "UInt64",
    ]

    let schema: Schema
    /// The named types a command result reaches: values a newer daemon writes.
    let decoded: Set<String>
    /// Every top-level name the generated module declares or spells.
    let reservedNames: Set<String>

    init(schema: Schema) throws(TypeSchemaError) {
        self.schema = schema
        decoded = schema.closure(of: schema.commands.flatMap(\.result.refs))
        let support = Set(WireIDType.all.map(\.name) + [Self.wireJSON, Self.anyKey])
        let taken = support.union(Self.hostTypeNames).union(Self.standardTypeNames)
        for name in schema.types.keys.sorted() where taken.contains(name) {
            throw TypeSchemaError(path: "$.types.\(name)", message: "collides with a Swift, CmuxNextIPC or generated support type")
        }
        reservedNames = taken.union(schema.types.keys)
    }

    init(sdkSchema: Data) throws(TypeSchemaError) {
        try self.init(schema: try Schema(sdkSchema: sdkSchema))
    }

    static let wireJSON = "WireJSON"
    static let anyKey = "WireAnyKey"

    // Files -----------------------------------------------------------------

    /// The file holding the named types `family` owns.
    static func fileName(family: String) -> String {
        "WireTypes+\(SwiftNames(family).type).swift"
    }

    static let supportFileName = "WireTypes+Support.swift"
    /// The owner of the types only commands without a method id reach.
    static let unframedFamily = "unframed"

    /// Every output file name, in the order ``files()`` returns them: the
    /// support file, one per command family of the schema and one for
    /// `unframed`. CmuxNextWireGenPlugin declares the same list, read from the
    /// same `families` table.
    static func fileNames(commandFamilies: [String]) -> [String] {
        [supportFileName] + (commandFamilies + [unframedFamily]).sorted().map { fileName(family: $0) }
    }

    /// The support file and one file per command family (written even when the
    /// family owns no type, so the build always gets the files it declared). A
    /// family owns the named types its commands reach before any command of a
    /// lower method id does. Two runs over the same schema give the same bytes.
    func files() throws(TypeSchemaError) -> [GeneratedSource] {
        guard !schema.commandFamilies.contains(Self.unframedFamily) else {
            throw TypeSchemaError(path: "$.families.\(Self.unframedFamily)", message: "is the name of the unframed types' file")
        }
        var owner: [String: String] = [:]
        for command in schema.commands {
            let family = command.family ?? Self.unframedFamily
            for name in schema.closure(of: command.refs) where owner[name] == nil {
                owner[name] = family
            }
        }
        var owned: [String: [String]] = [:]
        for (name, family) in owner {
            owned[family, default: []].append(name)
        }
        var out = [GeneratedSource(fileName: Self.supportFileName, text: Self.supportSource())]
        for family in (schema.commandFamilies + [Self.unframedFamily]).sorted() {
            var text = Self.header("The named types the `clients: macos` commands of family \(family) reach first")
            for name in (owned[family] ?? []).sorted() {
                text += "\n" + (try declaration(named: name))
            }
            out.append(GeneratedSource(fileName: Self.fileName(family: family), text: text))
        }
        return out
    }

    static func header(_ subject: String) -> String {
        """
        // Generated by CmuxNextWireGen (TypeEmitter) from cmux-tui/spec/sdk-schema.json at build
        // time. Do not edit; never committed.
        // \(subject).

        """
    }

    /// The top-level declaration of the named type `name`.
    func declaration(named name: String) throws(TypeSchemaError) -> String {
        guard let type = schema.types[name] else {
            throw TypeSchemaError(path: "$.types.\(name)", message: "is not a type the app's commands reach")
        }
        let scope = Scope(path: "$.types.\(name)", indent: "", enclosing: [], extensible: decoded.contains(name),
                          recursive: schema.holdsItself(name, throughUnions: true))
        switch type {
        case .object(let object):
            if schema.holdsItself(name, throughUnions: false) {
                throw TypeSchemaError(path: scope.path, message: "holds itself outside an array, map or union")
            }
            return try structDeclaration(name, object: object, scope: scope)
        case .enumeration(let enumeration):
            return try enumDeclaration(name, enumeration: enumeration, scope: scope)
        case .taggedUnion(let union):
            return try taggedUnionDeclaration(name, union: union, scope: scope)
        case .untaggedUnion(let variants):
            return try untaggedUnionDeclaration(name, variants: variants, scope: scope)
        case .literal:
            throw TypeSchemaError(path: scope.path, message: "a named type cannot be a literal")
        case .scalar, .alias, .array, .map, .ref, .opaqueJSON:
            var nested: [String] = []
            var taken: Set<String> = []
            let target = try swiftType(type, member: nil, nestAs: name, scope: scope, nested: &nested, taken: &taken)
            guard nested.isEmpty else {
                throw TypeSchemaError(path: scope.path, message: "an alias of an inline type needs a name of its own")
            }
            return "public typealias \(name) = \(target)\n"
        }
    }

    // Type expressions ------------------------------------------------------

    /// The Swift type of `type` as the member with wire name `member` holds
    /// it. An inline object, enum or union becomes a nested declaration named
    /// `nestAs` (or the next free name), appended to `nested`. A member the id
    /// map names (``WireIDType``) gets its typed id.
    func swiftType(
        _ type: Schema.TypeExpr,
        member: String?,
        nestAs: String,
        scope: Scope,
        nested: inout [String],
        taken: inout Set<String>
    ) throws(TypeSchemaError) -> String {
        if let id = idType(type, member: member) { return id.name }
        switch type {
        case .scalar(let scalar):
            return scalar.swiftName
        case .ref(let name):
            return name
        case .alias(let target):
            return try swiftType(target, member: member, nestAs: nestAs, scope: scope, nested: &nested, taken: &taken)
        case .array(let items):
            let item = try swiftType(items, member: member, nestAs: nestAs + "Item", scope: scope, nested: &nested, taken: &taken)
            return "[\(item)]"
        case .map(let values):
            let value = try swiftType(values, member: nil, nestAs: nestAs + "Value", scope: scope, nested: &nested, taken: &taken)
            return "[String: \(value)]"
        case .opaqueJSON:
            return Self.wireJSON
        case .literal:
            throw TypeSchemaError(path: scope.path, message: "a literal is a member's constant, not a member type")
        case .object, .enumeration, .taggedUnion, .untaggedUnion:
            break
        }
        let name = freeTypeName(nestAs, scope: scope, taken: &taken)
        switch type {
        case .object(let object): nested.append(try structDeclaration(name, object: object, scope: scope))
        case .enumeration(let enumeration): nested.append(try enumDeclaration(name, enumeration: enumeration, scope: scope))
        case .taggedUnion(let union): nested.append(try taggedUnionDeclaration(name, union: union, scope: scope))
        case .untaggedUnion(let variants): nested.append(try untaggedUnionDeclaration(name, variants: variants, scope: scope))
        default: break
        }
        return name
    }

    /// The typed id of a scalar (or alias of a scalar) member the id map names.
    func idType(_ type: Schema.TypeExpr, member: String?) -> WireIDType? {
        switch type {
        case .scalar(let scalar): WireIDType.forMember(member, scalar: scalar)
        case .alias(let target): idType(target, member: member)
        case .ref(let name): schema.types[name].flatMap { idType($0, member: member) }
        default: nil
        }
    }

    /// `base`, or `base` + `Value` until it shadows no type in scope.
    func freeTypeName(_ base: String, scope: Scope, taken: inout Set<String>) -> String {
        var name = base
        while taken.contains(name) || reservedNames.contains(name) || scope.enclosing.contains(name) {
            name += "Value"
        }
        taken.insert(name)
        return name
    }

    /// The type an expression names, through aliases and refs.
    func resolved(_ type: Schema.TypeExpr) -> Schema.TypeExpr {
        switch type {
        case .alias(let target): resolved(target)
        case .ref(let name): schema.types[name].map(resolved) ?? type
        default: type
        }
    }

    /// The Swift expression of a member's non-null schema `default`.
    /// `typeName` is the member's Swift type; an enum value is written qualified
    /// by it, so a case named `none` never reads as `Optional.none`.
    func defaultExpression(
        _ value: SchemaJSON,
        field: Schema.Field,
        typeName: String,
        scope: Scope,
        path: String
    ) throws(TypeSchemaError) -> String {
        let target = resolved(field.type)
        if let id = idType(field.type, member: field.name), case .scalar(let scalar) = target,
           let raw = Self.scalarLiteral(value, scalar) {
            return "\(id.name)(rawValue: \(raw))"
        }
        switch (target, value) {
        case (.scalar(let scalar), _):
            if let literal = Self.scalarLiteral(value, scalar) { return literal }
        case (.enumeration(let enumeration), .string(let text)) where enumeration.values.contains(text):
            return typeName + Self.enumCase(text, of: enumeration, extensible: isExtensible(field.type, scope: scope))
        case (.array, .array(let items)) where items.isEmpty:
            return "[]"
        case (.map, .object(let members)) where members.isEmpty:
            return "[:]"
        default:
            break
        }
        throw TypeSchemaError(path: "\(path).default", message: "has no Swift literal for its member type")
    }

    /// Whether the enum or union `type` names keeps values it does not know:
    /// a named one when a command result reaches it, an inline one when its
    /// enclosing named type is.
    func isExtensible(_ type: Schema.TypeExpr, scope: Scope) -> Bool {
        switch type {
        case .ref(let name):
            if case .alias(let target)? = schema.types[name] { return isExtensible(target, scope: scope) }
            return decoded.contains(name)
        case .alias(let target): return isExtensible(target, scope: scope)
        default: return scope.extensible
        }
    }

    static func scalarLiteral(_ value: SchemaJSON, _ scalar: Schema.Scalar) -> String? {
        switch (scalar, value) {
        case (.boolean, .bool(let flag)): String(flag)
        case (.string, .string(let text)): SwiftNames.literal(text)
        case (_, .integer(let number)) where scalar.isInteger || scalar.isFloat: String(number)
        case (_, .number(let number)) where scalar.isFloat: String(number)
        default: nil
        }
    }
}
