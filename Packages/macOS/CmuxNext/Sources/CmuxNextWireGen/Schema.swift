import Foundation

// The type grammar of cmux-tui/spec/sdk-schema.json (sdk-schema.schema.json
// `typeExpr`, `field`, `command`) as TypeEmitter reads it (p05-ipc-020). The
// codegen validator (cmux-tui/bindings/codegen/validate.py) owns the full rule
// set; TypeSchemaParser refuses only what the Swift emitter cannot write.

/// Why a schema type cannot become Swift. `path` is a JSON path into sdk-schema.json.
struct TypeSchemaError: Error, Equatable, CustomStringConvertible {
    let path: String
    let message: String

    var description: String { "\(MethodTableSchema.sdkFile): \(path): \(message)" }
}

/// The commands one client calls and every named type they reach, read from
/// sdk-schema.json. Named types nothing reaches are not read at all, so a type
/// only another client uses can never fail the app's build.
struct TypeSchema: Equatable {
    enum Scalar: String, Equatable {
        case string, boolean, int32, uint16, uint32, int64, uint64, float32, float64

        var swiftName: String {
            switch self {
            case .string: "String"
            case .boolean: "Bool"
            case .int32: "Int32"
            case .uint16: "UInt16"
            case .uint32: "UInt32"
            case .int64: "Int64"
            case .uint64: "UInt64"
            case .float32: "Float"
            case .float64: "Double"
            }
        }

        var isInteger: Bool {
            switch self {
            case .int32, .uint16, .uint32, .int64, .uint64: true
            case .string, .boolean, .float32, .float64: false
            }
        }

        var isFloat: Bool { self == .float32 || self == .float64 }
    }

    /// One `typeExpr`. Members keep their schema order only where the schema
    /// has one (enum values, untagged variants); object members and tagged
    /// variants are sorted by wire name, so the output never depends on the
    /// JSON reader's dictionary order.
    indirect enum TypeExpr: Equatable {
        case scalar(Scalar)
        /// A string, boolean, integer, number or null constant.
        case literal(SchemaJSON)
        case enumeration(Enumeration)
        case object(Object)
        case alias(TypeExpr)
        case taggedUnion(TaggedUnion)
        case untaggedUnion([TypeExpr])
        case array(TypeExpr)
        case map(TypeExpr)
        case ref(String)
        case opaqueJSON

        /// Every named type this expression mentions, through arrays and maps too.
        var refs: [String] {
            switch self {
            case .ref(let name): [name]
            case .object(let object): object.refs
            case .alias(let target), .array(let target), .map(let target): target.refs
            case .taggedUnion(let union): union.variants.flatMap(\.object.refs)
            case .untaggedUnion(let variants): variants.flatMap(\.refs)
            case .scalar, .literal, .enumeration, .opaqueJSON: []
            }
        }

        /// The named types a value of this expression holds inline: not through
        /// an array or a map (they box), and not through a union unless
        /// `throughUnions` (an `indirect` enum boxes).
        func valueRefs(throughUnions: Bool) -> [String] {
            switch self {
            case .ref(let name): [name]
            case .object(let object): object.fields.flatMap { $0.type.valueRefs(throughUnions: throughUnions) }
            case .alias(let target): target.valueRefs(throughUnions: throughUnions)
            case .taggedUnion(let union):
                throughUnions ? union.variants.flatMap { TypeExpr.object($0.object).valueRefs(throughUnions: true) } : []
            case .untaggedUnion(let variants):
                throughUnions ? variants.flatMap { $0.valueRefs(throughUnions: true) } : []
            case .scalar, .literal, .enumeration, .opaqueJSON, .array, .map: []
            }
        }
    }

    /// One object member (`field`).
    struct Field: Equatable {
        let name: String
        let type: TypeExpr
        let required: Bool
        let nullable: Bool
        /// The schema's `default`: nil when it gives none, `.null` for `default: null`.
        let defaultValue: SchemaJSON?
        /// `omit_nil`: encoders omit the member instead of writing null.
        let omitNil: Bool
        /// Other wire names decoders accept for this member.
        let aliases: [String]
        /// The schema's `description`, written as the member's doc comment.
        let summary: String?
    }

    struct Object: Equatable {
        /// Sorted by wire name.
        let fields: [Field]

        var refs: [String] { fields.flatMap(\.type.refs) }
    }

    struct Enumeration: Equatable {
        /// In schema order.
        let values: [String]
        /// The value decoders give a string they do not know (`fallback`).
        let fallback: String?
    }

    struct Variant: Equatable {
        /// The tag member's value, also the variant's key in the schema.
        let tag: String
        let object: Object
    }

    struct TaggedUnion: Equatable {
        /// The member every variant carries as a literal.
        let tagField: String
        /// Sorted by tag.
        let variants: [Variant]
    }

    struct Command: Equatable {
        let name: String
        /// The kebab-case family of its `method_id`; nil for a command with no id.
        let family: String?
        let methodID: UInt16?
        let request: Object
        let result: TypeExpr

        var refs: [String] { request.refs + result.refs }
    }

    /// The commands `client` calls, by method id (commands with no id last), then name.
    let commands: [Command]
    /// Every named type those commands reach, by name.
    let types: [String: TypeExpr]
    /// The declared families of the command id space (0x01-0x5F), by name.
    let commandFamilies: [String]

    init(sdkSchema: Data, client: String = MethodTableSchema.macOSClient) throws(TypeSchemaError) {
        let document: SchemaJSON
        do {
            document = try JSONDecoder().decode(SchemaJSON.self, from: sdkSchema)
        } catch {
            throw TypeSchemaError(path: "$", message: "not JSON: \(error)")
        }
        try self.init(sdk: document, client: client)
    }

    init(sdk: SchemaJSON, client: String = MethodTableSchema.macOSClient) throws(TypeSchemaError) {
        let parser = try TypeSchemaParser(document: sdk)
        var commands = try parser.commands(client: client)
        commands.sort { lhs, rhs in
            (lhs.methodID ?? .max, lhs.name) < (rhs.methodID ?? .max, rhs.name)
        }
        var types: [String: TypeExpr] = [:]
        var pending = commands.flatMap(\.refs)
        while let name = pending.popLast() {
            guard types[name] == nil else { continue }
            let type = try parser.namedType(name)
            types[name] = type
            pending.append(contentsOf: type.refs)
        }
        self.commands = commands
        self.types = types
        commandFamilies = parser.families
            .filter { MethodTableSchema.Space.v12.range.contains($0.key) }
            .map(\.value)
            .sorted()
    }

    /// `roots` and every named type they reach.
    func closure(of roots: [String]) -> Set<String> {
        var reached = Set<String>()
        var pending = roots
        while let name = pending.popLast() {
            guard reached.insert(name).inserted, let type = types[name] else { continue }
            pending.append(contentsOf: type.refs)
        }
        return reached
    }

    /// Whether a value of the named type holds itself inline (see
    /// ``TypeExpr/valueRefs(throughUnions:)``).
    func holdsItself(_ name: String, throughUnions: Bool) -> Bool {
        var seen = Set<String>()
        var pending = types[name]?.valueRefs(throughUnions: throughUnions) ?? []
        while let next = pending.popLast() {
            if next == name { return true }
            guard seen.insert(next).inserted, let type = types[next] else { continue }
            pending.append(contentsOf: type.valueRefs(throughUnions: throughUnions))
        }
        return false
    }
}
