import Foundation

/// Writes the Swift source of the `cmux.protocol/2` operations the macOS app calls, for
/// CmuxNextIPC (p05-ipc.md task 024), from cmux-tui/spec/resource-operations-v2.json:
///
/// - a typed id per resource scope (`V2TerminalID`);
/// - every catalog type those operations reach (`V2<Name>`): objects as structs with explicit
///   CodingKeys and coding, enums as open `RawRepresentable` structs, tagged unions as enums;
/// - `V2ResourceError`, the catalog's errors with each code's typed `details`;
/// - a `V2<Operation>Request` per operation: its params (selectors first, `machine` and
///   `session` defaulting to `current`; an optional nullable field as `ResourceFieldUpdate`, so
///   `null` can clear it), its `Result` and, for a stream, `StreamItem`/`StreamEnd`.
///
/// This is Chromium's Mojo bindings generator for cmux (mojo/public/tools/bindings/generators/
/// mojom_cpp_generator.py): a typed params struct and response type per method, the message
/// built from the struct instead of by hand, one output file per mojom, here per operation family
/// (`ResourceOperations+terminal.swift`) with the types several families share in
/// `ResourceOperations.swift`, so a family edit recompiles one small file. It differs in two
/// places. Mojo's `[Extensible]` enums (mojo/public/tools/bindings/README.md) turn a value this
/// build does not know into the enum's `[Default]`; cmux enums are open string structs that keep
/// the value, and an unknown union variant or error code keeps its raw JSON, because the app
/// shows, logs and sends back what a newer daemon (a Cloud VM, a remote host) wrote. And Mojo
/// generates every method of an interface; this generates only the operations the caller names
/// (the plugin's `appResourceOperations`), as p05-ipc.md limits generated Swift to the app's.
///
/// The hand-written half is in CmuxNextIPC: `ResourceRequestLine` (the envelope builder that
/// replaces hand-built `ResourceRequestEnvelope`s), `ResourceResponse`, `ResourceJSON`,
/// `ResourceSelector`, `ResourceFieldUpdate` and the request protocols.
struct ResourceEmitter {
    /// One generated file: its name in the output directory and its source.
    struct File: Equatable {
        let name: String
        let text: String
    }

    /// One operation family (the name before the first dot): its operations and the named types
    /// only they reach.
    struct Family: Equatable {
        let name: String
        let operationNames: [String]
        let typeNames: [String]
    }

    /// The ids, the types several families (or the errors) reach, the errors and `Response`.
    static let sharedFileName = "ResourceOperations.swift"

    /// The file of `family`; CmuxNextWireGenPlugin declares the same names as the command's outputs.
    static func fileName(family: String) -> String {
        "ResourceOperations+\(family).swift"
    }

    let catalog: ResourceCatalog
    let operationNames: [String]
    let families: [Family]
    let sharedTypeNames: [String]
    let renderer: ResourceTypeRenderer

    /// The bindings of `operations` (each once, any order). A name the catalog does not declare,
    /// or whose `clients` leave out `client`, is refused; an operation without `clients` serves
    /// every client, as in MethodTableSchema.
    init(catalog: ResourceCatalog, operations: [String],
         client: String = MethodTableSchema.macOSClient) throws(ResourceEmitterError) {
        let names = Set(operations).sorted()
        var byFamily: [String: [String]] = [:]
        for name in names {
            guard let operation = catalog.operations[name] else { throw .unknownOperation(name) }
            if let clients = operation.clients, !clients.contains(client) {
                throw .notForClient(operation: name, client: client)
            }
            let family = String(name.prefix { $0 != "." })
            guard !family.isEmpty, family.unicodeScalars.allSatisfy(Self.isFileNameScalar) else {
                throw .unsupported(path: "$.operations.\(name)", reason: "its family `\(family)` is not a file name")
            }
            byFamily[family, default: []].append(name)
        }
        var reached: [String: Set<String>] = [:]
        var reachCount: [String: Int] = [:]
        for (family, members) in byFamily {
            var roots: [String] = []
            for name in members { roots += try catalog.typeReferences(operation: name) }
            let types = try catalog.reachableTypeNames(from: roots)
            reached[family] = types
            for type in types { reachCount[type, default: 0] += 1 }
        }
        var shared = try catalog.reachableTypeNames(from: catalog.errorTypeReferences)
        shared.formUnion(reachCount.filter { $0.value > 1 }.keys)
        self.catalog = catalog
        self.operationNames = names
        self.families = byFamily.keys.sorted().map { family in
            Family(name: family, operationNames: byFamily[family] ?? [],
                   typeNames: (reached[family] ?? []).subtracting(shared).sorted())
        }
        self.sharedTypeNames = shared.sorted()
        self.renderer = ResourceTypeRenderer(catalog: catalog)
    }

    init(resourceOperations: Data, operations: [String]) throws(ResourceEmitterError) {
        try self.init(catalog: ResourceCatalog(data: resourceOperations), operations: operations)
    }

    /// The shared file, then one file per family in name order. Two runs over the same catalog
    /// and operations write the same bytes.
    func files() throws(ResourceEmitterError) -> [File] {
        let shared = try sharedDeclarations()
        var perFamily: [[ResourceDeclaration]] = []
        for family in families {
            perFamily.append(try declarations(of: family))
        }
        try ResourceTypeRenderer.checkUnique((shared + perFamily.flatMap { $0 }).map(\.name), path: "$")
        let response = [
            "",
            "extension ResourceOperationRequest {",
            "    /// This request's response line: its `Result`, or the catalog's typed error.",
            "    public typealias Response = ResourceResponse<Self.Result, \(Self.errorTypeName)>",
            "}",
        ]
        var out = [File(name: Self.sharedFileName, text: Self.text(shared, footer: response))]
        for (family, declarations) in zip(families, perFamily) {
            out.append(File(name: Self.fileName(family: family.name), text: Self.text(declarations, footer: [])))
        }
        return out
    }

    /// Ids, shared types and errors, each group sorted by name.
    func sharedDeclarations() throws(ResourceEmitterError) -> [ResourceDeclaration] {
        var out = try identifiers()
        for name in sharedTypeNames {
            out += try renderer.declarations(named: name)
        }
        out += try errorDeclarations()
        return out
    }

    /// The family's own types, then its requests, each group sorted by name.
    func declarations(of family: Family) throws(ResourceEmitterError) -> [ResourceDeclaration] {
        var out: [ResourceDeclaration] = []
        for name in family.typeNames {
            out += try renderer.declarations(named: name)
        }
        for name in family.operationNames {
            out.append(.object(try request(name)))
        }
        return out
    }

    private static func text(_ declarations: [ResourceDeclaration], footer: [String]) -> String {
        var writer = ResourceSourceWriter()
        writer.line("// Generated by CmuxNextWireGen (ResourceEmitter) from cmux-tui/spec/resource-operations-v2.json")
        writer.line("// at build time. Do not edit; never committed.")
        writer.line("// swiftlint:disable all")
        for declaration in declarations {
            writer.line("")
            writer.write(declaration)
        }
        for text in footer { writer.line(text) }
        return writer.lines.joined(separator: "\n") + "\n"
    }

    private static func isFileNameScalar(_ scalar: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) || scalar == "_"
    }

    private func identifiers() throws(ResourceEmitterError) -> [ResourceDeclaration] {
        var out: [ResourceDeclaration] = []
        for scope in catalog.resourceScopes.sorted() {
            let name = try ResourceSwiftName.identifier(scope: scope, path: "$.resource_scopes")
            out.append(.identifier(name: name, scope: scope))
        }
        return out
    }

    /// One operation's request: selectors in `resource_scopes` order, then fields by name.
    func request(_ name: String) throws(ResourceEmitterError) -> ResourceDeclaration.Object {
        guard let operation = catalog.operations[name] else { throw .unknownOperation(name) }
        let path = "$.operations.\(name)"
        let swiftName = try ResourceSwiftName.prefix + ResourceSwiftName.upperCamel(name, path: path) + "Request"
        var fields: [ResourceDeclaration.Field] = []
        for scope in catalog.resourceScopes {
            guard let requirement = operation.params.selectors[scope] else { continue }
            fields.append(try selector(scope, requirement: requirement, path: path + ".params.selectors.\(scope)"))
        }
        if let unknown = Set(operation.params.selectors.keys).subtracting(catalog.resourceScopes).sorted().first {
            throw .unsupported(path: path + ".params.selectors.\(unknown)", reason: "not a resource scope")
        }
        var nested: [ResourceDeclaration] = []
        for wireName in operation.params.fields.keys.sorted() {
            guard let field = operation.params.fields[wireName] else { continue }
            var member = try renderer.field(wireName, field, path: path + ".params.fields.\(wireName)", nested: &nested)
            // Absent keeps, `null` clears: a request needs all three states (`workspace.update`'s `title`).
            if member.presence == .optional, case .nullable = field.type { member.presence = .optionalNullable }
            fields.append(member)
        }
        var header = ["public static let resourceOperation = \(ResourceSourceWriter.literal(name))"]
        header += try associatedType("Result", operation.result, path: path + ".result", nested: &nested)
        let conformance = try Self.conformance(operation, path: path)
        if let stream = operation.stream {
            header += try associatedType("StreamItem", stream.item, path: path + ".stream.item", nested: &nested)
            header += try associatedType("StreamEnd", stream.end, path: path + ".stream.end", nested: &nested)
        }
        try ResourceTypeRenderer.checkUnique(fields.map(\.member.spelling), path: path + ".params")
        try ResourceTypeRenderer.checkUnique(nested.map(\.name), path: path)
        let errors = operation.errors.sorted().map { "`\($0)`" }.joined(separator: ", ")
        return ResourceDeclaration.Object(
            name: swiftName,
            conformances: conformance + ", Equatable",
            doc: ["/// `\(name)` (\(operation.`class`)). Errors: \(errors)."],
            header: header,
            fields: fields,
            nested: nested,
            decodes: false
        )
    }

    /// The request protocol, from `idempotency`: `required` is a mutation (the envelope builder
    /// takes a key), `forbidden` a read or a stream open (it takes none). A stream with a key, or
    /// any other value, would build a request the daemon refuses, so it is refused here.
    private static func conformance(_ operation: ResourceCatalog.Operation,
                                    path: String) throws(ResourceEmitterError) -> String {
        switch operation.idempotency {
        case "required":
            guard operation.stream == nil else {
                throw .unsupported(path: path + ".idempotency", reason: "a stream takes no idempotency key")
            }
            return "ResourceMutationRequest"
        case "forbidden":
            return operation.stream == nil ? "ResourceUnkeyedRequest" : "ResourceStreamRequest"
        default:
            throw .unsupported(path: path + ".idempotency",
                               reason: "idempotency is required or forbidden, not \(operation.idempotency)")
        }
    }

    /// A selector parameter. `machine` and `session` default to `current`, the connected owner and
    /// session, as hand-built envelopes filled them in; other required selectors have no default.
    private func selector(_ scope: String, requirement: String,
                          path: String) throws(ResourceEmitterError) -> ResourceDeclaration.Field {
        let presence: ResourceDeclaration.Presence
        switch requirement {
        case "required": presence = .required
        case "optional": presence = .optional
        default: throw .unsupported(path: path, reason: "a selector is required or optional, not \(requirement)")
        }
        let defaultsToCurrent = presence == .required && (scope == "machine" || scope == "session")
        return ResourceDeclaration.Field(
            member: try ResourceSwiftName.member(scope, path: path), wireName: scope, type: "ResourceSelector",
            presence: presence, defaultArgument: defaultsToCurrent ? ".current" : nil, doc: [])
    }

    /// `typealias <role> = <type>`, or nothing when the type is an inline one already nested
    /// under that name.
    private func associatedType(_ role: String, _ expr: ResourceTypeExpr, path: String,
                                nested: inout [ResourceDeclaration]) throws(ResourceEmitterError) -> [String] {
        let type = try renderer.swiftType(expr, hint: role, path: path, nested: &nested)
        return type == role ? [] : ["public typealias \(role) = \(type)"]
    }
}
