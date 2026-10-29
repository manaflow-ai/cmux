import Foundation

// Writes the Swift wire types the app's commands reach (design
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
// enum and union a command result or an event reaches is extensible; one the
// app only sends stays closed. Every generated top-level name is `Wire` + the
// schema name (`WirePane`), so a module that imports CmuxNextIPC next to
// CmuxNextDaemon or SwiftUI never sees an ambiguous `Pane`, `PaneID` or
// `Layout`. The output is a pure function of the schema bytes.

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
        "Any", "Array", "Bool", "CodingKey", "Codable", "Decodable", "Decoder", "DecodingError",
        "Dictionary", "Double", "Encodable", "Encoder", "EncodingError", "Equatable", "Error", "Float", "Hashable",
        "Int", "Int32", "Int64", "Never", "Optional", "Protocol", "RawRepresentable", "Self", "Sendable", "String",
        "Swift", "Type", "UInt16", "UInt32", "UInt64",
    ]

    /// The types every generated declaration nests: no nested type may take one of these names.
    static let memberTypeNames: Set<String> = ["CodingKeys", "TagKey"]

    let schema: Schema
    /// The named types a command result or an event reaches: values a newer daemon writes.
    let decoded: Set<String>
    /// Every name a nested declaration must not take: the module's top-level
    /// names, the standard library's and the generated members'.
    let reservedNames: Set<String>

    init(schema: Schema) throws(TypeSchemaError) {
        self.schema = schema
        decoded = schema.decodedTypes
        do {
            _ = try WireTypeFiles(typeNames: schema.types.keys)
        } catch {
            throw TypeSchemaError(path: error.path, message: error.message)
        }
        let support = Set(WireIDType.declaredNames + [Self.wireJSON, Self.anyKey])
        let taken = support.union(Self.hostTypeNames).union(Self.standardTypeNames)
        for name in schema.types.keys.sorted() where taken.contains(Self.swiftName(ofType: name)) {
            throw TypeSchemaError(
                path: "$.types.\(name)",
                message: "\(Self.swiftName(ofType: name)) collides with a Swift, CmuxNextIPC or generated support type"
            )
        }
        reservedNames = taken.union(Self.memberTypeNames).union(schema.types.keys.map(Self.swiftName(ofType:)))
    }

    init(sdkSchema: Data) throws(TypeSchemaError) {
        try self.init(schema: try Schema(sdkSchema: sdkSchema))
    }

    static let wireJSON = "WireJSON"
    static let anyKey = "WireAnyKey"

    /// The Swift name of the schema's named type `name`.
    static func swiftName(ofType name: String) -> String { "Wire" + name }

    // Files -----------------------------------------------------------------

    /// The support files, then one file per named type the client's commands
    /// reach, by name: ``WireTypeFiles``, the list CmuxNextWireGenPlugin declares.
    /// Two runs over the same schema give the same bytes.
    func files() throws(TypeSchemaError) -> [GeneratedSource] {
        let list: WireTypeFiles
        do {
            list = try WireTypeFiles(typeNames: schema.commandTypes)
        } catch {
            throw TypeSchemaError(path: error.path, message: error.message)
        }
        var out = Self.supportSources()
        for name in list.typeNames {
            let text = Self.header("The wire type `\(name)` of the `clients: macos` commands") + "\n"
                + (try declaration(named: name))
            out.append(GeneratedSource(fileName: WireTypeFiles.fileName(type: name), text: text))
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
        let swiftName = Self.swiftName(ofType: name)
        switch type {
        case .object(let object):
            if schema.holdsItself(name, throughUnions: false) {
                throw TypeSchemaError(path: scope.path, message: "holds itself outside an array, map or union")
            }
            return try structDeclaration(swiftName, object: object, scope: scope)
        case .enumeration(let enumeration):
            return try enumDeclaration(swiftName, enumeration: enumeration, scope: scope)
        case .taggedUnion(let union):
            return try taggedUnionDeclaration(swiftName, union: union, scope: scope)
        case .untaggedUnion(let variants):
            return try untaggedUnionDeclaration(swiftName, variants: variants, scope: scope)
        case .literal:
            throw TypeSchemaError(path: scope.path, message: "a named type cannot be a literal")
        case .scalar, .alias, .array, .map, .ref, .opaqueJSON:
            var nested: [String] = []
            var taken: Set<String> = []
            let target = try swiftType(type, member: nil, nestAs: swiftName, scope: scope, nested: &nested, taken: &taken)
            guard nested.isEmpty else {
                throw TypeSchemaError(path: scope.path, message: "an alias of an inline type needs a name of its own")
            }
            return "public typealias \(swiftName) = \(target)\n"
        }
    }

    // Type expressions ------------------------------------------------------

    /// The Swift type of `type` as the member with wire name `member` at
    /// `scope.path` holds it. An inline object, enum or union becomes a nested
    /// declaration named `nestAs` (or the next free name), appended to `nested`.
    /// A member the id map names (``WireIDType``) gets its typed id.
    func swiftType(
        _ type: Schema.TypeExpr,
        member: String?,
        nestAs: String,
        scope: Scope,
        nested: inout [String],
        taken: inout Set<String>
    ) throws(TypeSchemaError) -> String {
        if let id = idType(type, member: member, at: scope.path) { return id.name }
        switch type {
        case .scalar(let scalar):
            return scalar.swiftName
        case .ref(let name):
            return Self.swiftName(ofType: name)
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

    /// The typed id of a scalar (or alias of a scalar) member the id map names;
    /// `path` is the member's JSON path.
    func idType(_ type: Schema.TypeExpr, member: String?, at path: String) -> WireIDType? {
        switch type {
        case .scalar(let scalar): WireIDType.forMember(member, at: path, scalar: scalar)
        case .alias(let target): idType(target, member: member, at: path)
        case .ref(let name): schema.types[name].flatMap { idType($0, member: member, at: path) }
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
        if let id = idType(field.type, member: field.name, at: path), case .scalar(let scalar) = target,
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
