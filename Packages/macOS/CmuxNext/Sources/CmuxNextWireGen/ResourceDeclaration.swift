/// One Swift declaration ResourceEmitter writes, before ResourceSourceWriter spells it. The
/// renderer builds these from catalog shapes; the writer only formats, so every naming and
/// shape decision is in ResourceTypeRenderer and ResourceEmitter.
indirect enum ResourceDeclaration {
    /// A struct with explicit CodingKeys, a memberwise init and explicit coding.
    case object(Object)
    /// An open string enum: a `RawRepresentable` struct with a static per known value, so a value
    /// a newer daemon sends still decodes and round-trips.
    case openEnum(name: String, doc: [String], values: [Value])
    /// A discriminated union: an `indirect enum` with a case per variant, decoded by its tag.
    case union(Union)
    case alias(name: String, doc: [String], target: String)
    /// The typed id of a resource scope: a `ResourceIdentifier` struct around the id string.
    case identifier(name: String, scope: String)
    /// A declaration the emitter spells itself (`V2ResourceError`, whose decode switches on a
    /// sibling key), one line per element, unindented.
    case source(name: String, lines: [String])

    /// How a field is present on the wire.
    enum Presence {
        /// Always present, never null.
        case required
        /// Always present, possibly null (`required` and `nullable` in the catalog).
        case requiredNullable
        /// May be absent; nil is not written. A nullable optional field decodes null as nil.
        case optional
        /// A request's optional nullable field: absent, `null` or a value, as
        /// `ResourceFieldUpdate<type>`, so a caller can clear what an optional cannot.
        case optionalNullable
    }

    struct Field {
        var member: ResourceSwiftName
        var wireName: String
        /// The Swift type without the optional marker presence adds.
        var type: String
        var presence: Presence
        /// The init parameter's default; nil means the presence's default (`nil` for optional).
        var defaultArgument: String?
        var doc: [String]

        var declaredType: String {
            switch presence {
            case .required: type
            case .requiredNullable, .optional: type + "?"
            case .optionalNullable: "ResourceFieldUpdate<\(type)>"
            }
        }
    }

    struct Object {
        var name: String
        /// `<T: ...>` for a generic, empty otherwise.
        var genericClause: String = ""
        var conformances: String
        var doc: [String]
        /// Members written before the fields (`static let`, `typealias`).
        var header: [String] = []
        var fields: [Field]
        var nested: [ResourceDeclaration]
        /// Whether to write `init(from:)`; requests only encode.
        var decodes: Bool = true
    }

    struct Value {
        var member: ResourceSwiftName
        var rawValue: String
    }

    struct Variant {
        var member: ResourceSwiftName
        /// The discriminator values that select this variant (one, or several sharing a shape).
        var tags: [String]
        var type: String
    }

    struct Union {
        var name: String
        var doc: [String]
        var discriminator: String
        var variants: [Variant]
        /// `unknown_variant`: an unrecognized tag keeps the raw object instead of failing.
        var keepsUnknown: Bool
    }
}
