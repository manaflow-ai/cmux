import Foundation

/// The `cmux.protocol/2` operation catalog (cmux-tui/spec/resource-operations-v2.json, shape in
/// resource-operations-v2.schema.json) as ResourceEmitter reads it. Dictionaries lose the file's
/// key order, so every consumer iterates sorted names (selectors in `resourceScopes` order): the
/// output depends only on the catalog's content.
struct ResourceCatalog: Decodable {
    struct Field: Decodable {
        var required: Bool
        var type: ResourceTypeExpr
        var description: String?
    }

    /// `params`: flat selectors (`machine`, `session`, ...; `required` or `optional`) and the
    /// operation's own fields.
    struct Params: Decodable {
        var selectors: [String: String]
        var fields: [String: Field]
    }

    struct Stream: Decodable {
        var item: ResourceTypeExpr
        var end: ResourceTypeExpr
    }

    struct Operation: Decodable {
        var `class`: String
        var idempotency: String
        var params: Params
        var result: ResourceTypeExpr
        var stream: Stream?
        var errors: [String]
        /// `macos`, `ios`, `cli`, `sdk` (p05-ipc.md section 3.3); absent is every client, the
        /// rule MethodTableSchema applies to the same operations.
        var clients: [String]?
    }

    struct ErrorDescriptor: Decodable {
        var retryable: Bool
        var details: ResourceTypeExpr
    }

    struct Generic: Decodable {
        var parameters: [String]
        var body: ResourceTypeExpr
    }

    var resourceScopes: [String]
    var types: [String: ResourceTypeExpr]
    var generics: [String: Generic]
    var errors: [String: ErrorDescriptor]
    var operations: [String: Operation]

    enum CodingKeys: String, CodingKey {
        case types, generics, errors, operations
        case resourceScopes = "resource_scopes"
    }

    init(data: Data) throws(ResourceEmitterError) {
        do {
            self = try JSONDecoder().decode(ResourceCatalog.self, from: data)
        } catch {
            throw .unreadableCatalog("\(error)")
        }
    }

    /// The named types and generics operation `name`'s params, result and stream mention.
    func typeReferences(operation name: String) throws(ResourceEmitterError) -> [String] {
        guard let operation = operations[name] else { throw .unknownOperation(name) }
        var out = operation.params.fields.values.flatMap(\.type.references) + operation.result.references
        if let stream = operation.stream { out += stream.item.references + stream.end.references }
        return out
    }

    /// The named types and generics the error details mention.
    var errorTypeReferences: [String] {
        errors.values.flatMap(\.details.references)
    }

    /// Every named type and generic reachable from `roots`. A name the catalog does not declare
    /// is refused.
    func reachableTypeNames(from roots: [String]) throws(ResourceEmitterError) -> Set<String> {
        var pending = roots
        var seen = Set<String>()
        while let name = pending.popLast() {
            guard seen.insert(name).inserted else { continue }
            if let type = types[name] {
                pending += type.references
            } else if let generic = generics[name] {
                pending += generic.body.references
            } else {
                throw .unknownType(name)
            }
        }
        return seen
    }
}

/// One `typeExpression` of the catalog schema. Length, range and item-count bounds are the
/// daemon's to check; the Swift types carry the shape only.
indirect enum ResourceTypeExpr: Decodable {
    case primitive(String)
    case resourceID(scope: String)
    case selector(scope: String)
    case ref(String)
    case parameter(String)
    case apply(String, arguments: [ResourceTypeExpr])
    case enumeration([String])
    case array(ResourceTypeExpr)
    case map(ResourceTypeExpr)
    case nullable(ResourceTypeExpr)
    case union(variants: [ResourceTypeExpr], discriminator: String?, keepsUnknown: Bool)
    case object(fields: [String: ResourceCatalog.Field])

    private enum Keys: String, CodingKey {
        case kind, name, resource, arguments, values, items, value, variants, discriminator, fields
        case unknownVariant = "unknown_variant"
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        switch kind {
        case "primitive": self = .primitive(try c.decode(String.self, forKey: .name))
        case "resource_id": self = .resourceID(scope: try c.decode(String.self, forKey: .resource))
        case "selector": self = .selector(scope: try c.decode(String.self, forKey: .resource))
        case "ref": self = .ref(try c.decode(String.self, forKey: .name))
        case "parameter": self = .parameter(try c.decode(String.self, forKey: .name))
        case "apply":
            self = .apply(try c.decode(String.self, forKey: .name),
                          arguments: try c.decode([ResourceTypeExpr].self, forKey: .arguments))
        // The schema also allows integer and boolean enum values; the catalog has only strings,
        // and a non-string value fails here instead of getting a guessed spelling.
        case "enum": self = .enumeration(try c.decode([String].self, forKey: .values))
        case "array": self = .array(try c.decode(ResourceTypeExpr.self, forKey: .items))
        case "map": self = .map(try c.decode(ResourceTypeExpr.self, forKey: .values))
        case "nullable": self = .nullable(try c.decode(ResourceTypeExpr.self, forKey: .value))
        case "union":
            self = .union(variants: try c.decode([ResourceTypeExpr].self, forKey: .variants),
                          discriminator: try c.decodeIfPresent(String.self, forKey: .discriminator),
                          keepsUnknown: c.contains(.unknownVariant))
        case "object": self = .object(fields: try c.decode([String: ResourceCatalog.Field].self, forKey: .fields))
        default:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "unknown type kind \(kind)")
        }
    }

    /// Named types and generics this expression mentions directly or through inline shapes.
    var references: [String] {
        switch self {
        case .primitive, .resourceID, .selector, .parameter, .enumeration: []
        case .ref(let name): [name]
        case .apply(let name, let arguments): [name] + arguments.flatMap(\.references)
        case .array(let inner), .map(let inner), .nullable(let inner): inner.references
        case .union(let variants, _, _): variants.flatMap(\.references)
        case .object(let fields): fields.values.flatMap(\.type.references)
        }
    }
}

/// Why ResourceEmitter refused the catalog. Each case names the place, so the schema author can
/// fix the catalog instead of getting Swift that does not compile.
enum ResourceEmitterError: Error, Equatable, CustomStringConvertible {
    case unreadableCatalog(String)
    case unknownOperation(String)
    case unknownType(String)
    /// A shape the Swift emitter has no spelling for, with its catalog path.
    case unsupported(path: String, reason: String)
    /// Two catalog names that would get the same Swift name, with the place of the second.
    case nameCollision(path: String, swiftName: String)
    /// A requested operation whose `clients` leave out the client the bindings are for.
    case notForClient(operation: String, client: String)

    var description: String {
        switch self {
        case .unreadableCatalog(let reason): "resource-operations-v2.json: not an operation catalog: \(reason)"
        case .unknownOperation(let name): "resource-operations-v2.json: no operation \(name)"
        case .unknownType(let name): "resource-operations-v2.json: \(name) is referenced but not declared"
        case .unsupported(let path, let reason): "resource-operations-v2.json: \(path): \(reason)"
        case .nameCollision(let path, let swiftName):
            "resource-operations-v2.json: \(path): its Swift name \(swiftName) is already taken"
        case .notForClient(let operation, let client):
            "resource-operations-v2.json: $.operations.\(operation).clients: does not include \(client)"
        }
    }
}
