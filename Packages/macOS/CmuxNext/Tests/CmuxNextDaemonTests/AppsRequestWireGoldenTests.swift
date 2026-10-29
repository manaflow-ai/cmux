import Foundation
import Testing
@testable import CmuxNextDaemon

/// The wire golden of every request in Sources/CmuxNextDaemon/Requests/Apps: the line
/// each one sends today, compared as JSON (key order does not count). The migration to the generated
/// `<Name>Request` types (CmuxNextWireGen RequestEmitter) must send the same lines; the generated coder
/// writes each member under its schema wire name, so a golden that holds here and after the migration
/// proves the bytes did not change.
///
/// `apps-provider-register` has three hand-written types and one generated type after the migration:
/// the plain registration `{families}`, the `agent_cli` one (same line, its own capability) and the
/// inventory opt-in `{families, inventory_watch: true}`. The goldens pin all three.
///
/// Dictionary-valued fields (WireKeyInventory.dictionaryFields): the `JsonValue` documents
/// `apps-mount.context`, `apps-dispatch.payload`, `apps-run.args` and `apps-provider-result.body`. They
/// are the app's own JSON and go out verbatim (``VerbatimFieldsRequest``), so their goldens carry
/// camelCase keys that the snake-case strategy would have renamed.
struct AppsRequestWireGoldenTests {
    /// One request's expected line, `id` and `cmd` included.
    struct Golden: Sendable, CustomTestStringConvertible {
        let name: String
        let type: String
        let encode: @Sendable () throws -> Data
        let command: String
        let fields: [String: JSONValue]

        init<R: DaemonRequest>(_ name: String, _ request: R, _ fields: [String: JSONValue]) {
            self.name = name
            type = String(describing: R.self)
            encode = { try WireCoding.encodeRequest(request, id: 1) }
            command = R.command
            var line = fields
            line["id"] = .number(1)
            line["cmd"] = .string(R.command)
            self.fields = line
        }

        var testDescription: String { name }
    }

    /// A document whose keys a snake-case coder would rename: verbatim fields must keep them.
    private static let appDocument: JSONValue = .object([
        "workspaceId": .string("w-1"),
        "pageSize": .number(20),
        "nested": .object(["camelKey": .array([.bool(true), .null])]),
    ])

    static let goldens: [Golden] = [
        Golden("apps-list", AppsListRequest(), [:]),
        Golden("apps-set", AppsSetRequest(idempotencyKey: "k-1", app: "com.example.notes", origin: "user"),
               ["idempotency_key": .string("k-1"), "app": .string("com.example.notes"), "origin": .string("user")]),
        Golden("apps-set with every field",
               AppsSetRequest(idempotencyKey: "k-2", app: "com.example.notes", origin: "script", installed: true,
                              enabled: false, hidden: true, sandboxed: false,
                              grant: AppsSetRequest.Grant(scope: "network", granted: true)),
               ["idempotency_key": .string("k-2"), "app": .string("com.example.notes"), "origin": .string("script"),
                "installed": .bool(true), "enabled": .bool(false), "hidden": .bool(true), "sandboxed": .bool(false),
                "grant": .object(["scope": .string("network"), "granted": .bool(true)])]),
        Golden("apps-logs", AppsLogsRequest(app: "com.example.notes", follow: false),
               ["app": .string("com.example.notes"), "follow": .bool(false)]),
        Golden("apps-logs following", AppsLogsRequest(app: "com.example.notes", follow: true),
               ["app": .string("com.example.notes"), "follow": .bool(true)]),
        // `mountID` has the CodingKey "mountId"; the snake-case strategy sends it as mount_id.
        Golden("apps-mount", AppsMountRequest(app: "com.example.notes", interface: "sidebar", mountID: "m-1",
                                              context: appDocument),
               ["app": .string("com.example.notes"), "interface": .string("sidebar"), "mount_id": .string("m-1"),
                "context": appDocument]),
        Golden("apps-mount with an empty context",
               AppsMountRequest(app: "com.example.notes", interface: "sidebar", mountID: "m-2", context: .object([:])),
               ["app": .string("com.example.notes"), "interface": .string("sidebar"), "mount_id": .string("m-2"),
                "context": .object([:])]),
        Golden("apps-unmount", AppsUnmountRequest(mountID: "m-1"), ["mount_id": .string("m-1")]),
        // `origin` defaults to "user": the supervisor mints the gesture token for it.
        Golden("apps-dispatch", AppsDispatchRequest(mountID: "m-1", node: "n-1", event: "click", payload: appDocument),
               ["mount_id": .string("m-1"), "node": .string("n-1"), "event": .string("click"),
                "payload": appDocument, "origin": .string("user")]),
        Golden("apps-dispatch from a script",
               AppsDispatchRequest(mountID: "m-1", node: "n-1", event: "change", payload: .string("v"),
                                   origin: "script"),
               ["mount_id": .string("m-1"), "node": .string("n-1"), "event": .string("change"),
                "payload": .string("v"), "origin": .string("script")]),
        Golden("apps-provider-register", AppsProviderRegisterRequest(families: ["coderouter", "credential"]),
               ["families": .array([.string("coderouter"), .string("credential")])]),
        Golden("apps-provider-register with agent_cli",
               AgentCLIProviderRegisterRequest(families: ["coderouter", "agent_cli"]),
               ["families": .array([.string("coderouter"), .string("agent_cli")])]),
        // The opt-in is a constant member: it is always sent, and always true.
        Golden("apps-provider-register with the inventory watch",
               AgentInventoryProviderRegisterRequest(families: ["agent_cli"]),
               ["families": .array([.string("agent_cli")]), "inventory_watch": .bool(true)]),
        Golden("apps-agent-inventory-changed", AgentInventoryProviderChangedRequest(demandSequence: 9),
               ["demand_sequence": .number(9)]),
        // `requestID` goes out as request_id; `body` is the op's ABI body, verbatim.
        Golden("apps-provider-result", AppsProviderResultRequest(requestID: 77, ok: true,
                                                                 body: .object(["value": appDocument, "revision": .number(3)])),
               ["request_id": .number(77), "ok": .bool(true),
                "body": .object(["value": appDocument, "revision": .number(3)])]),
        Golden("apps-provider-result failing",
               AppsProviderResultRequest(requestID: 78, ok: false, body: .object([
                   "code": .string("not_found"), "message": .string("no credential"), "retryable": .bool(false),
               ])),
               ["request_id": .number(78), "ok": .bool(false), "body": .object([
                   "code": .string("not_found"), "message": .string("no credential"), "retryable": .bool(false),
               ])]),
        Golden("apps-run", AppsRunRequest(app: "com.example.notes", op: "notes.list", args: appDocument,
                                          idempotencyKey: nil, origin: .script),
               ["app": .string("com.example.notes"), "op": .string("notes.list"), "args": appDocument,
                "origin": .string("script")]),
        Golden("apps-run keyed by the user",
               AppsRunRequest(app: "com.example.notes", op: "notes.create", args: .object(["title": .string("a")]),
                              idempotencyKey: "k-3", origin: .user),
               ["app": .string("com.example.notes"), "op": .string("notes.create"),
                "args": .object(["title": .string("a")]), "idempotency_key": .string("k-3"), "origin": .string("user")]),
        // A null `args` is sent as an explicit null, not left out.
        Golden("apps-run without args",
               AppsRunRequest(app: "com.example.notes", op: "notes.count", args: .null, idempotencyKey: nil,
                              origin: .script),
               ["app": .string("com.example.notes"), "op": .string("notes.count"), "args": .null,
                "origin": .string("script")]),
        Golden("apps-link-changed", AppsLinkChangedRequest(), [:]),
        Golden("apps-terminal-links", AppsTerminalLinksRequest(), [:]),
    ]

    /// The capability `DaemonConnection.request` checks before it sends each type; nil for the `apps-v1`
    /// commands, which their callers gate. After the migration the generated types carry no capability
    /// (it lives in CmuxNextIPC's MethodTable), so these per-type gates of `apps-provider-register` must
    /// move to its callers (AppProviderRegistration, AppProviderSession) and keep the same effect.
    static let capabilities: [String: String?] = [
        String(describing: AgentCLIProviderRegisterRequest.self): "agent-cli-app-provider-v1",
        String(describing: AgentInventoryProviderRegisterRequest.self): "agent-cli-app-invalidation-v1",
        String(describing: AgentInventoryProviderChangedRequest.self): "agent-cli-app-invalidation-v1",
    ]

    @Test(arguments: goldens)
    func sendsItsGoldenLine(_ golden: Golden) throws {
        let line = try JSONDecoder().decode(JSONValue.self, from: golden.encode())
        #expect(line == .object(golden.fields))
    }

    @Test func gatesOnItsCapability() {
        let gates: [String: String?] = [
            String(describing: AppsListRequest.self): AppsListRequest.requiredCapability,
            String(describing: AppsSetRequest.self): AppsSetRequest.requiredCapability,
            String(describing: AppsLogsRequest.self): AppsLogsRequest.requiredCapability,
            String(describing: AppsMountRequest.self): AppsMountRequest.requiredCapability,
            String(describing: AppsUnmountRequest.self): AppsUnmountRequest.requiredCapability,
            String(describing: AppsDispatchRequest.self): AppsDispatchRequest.requiredCapability,
            String(describing: AppsProviderRegisterRequest.self): AppsProviderRegisterRequest.requiredCapability,
            String(describing: AgentCLIProviderRegisterRequest.self): AgentCLIProviderRegisterRequest.requiredCapability,
            String(describing: AgentInventoryProviderRegisterRequest.self):
                AgentInventoryProviderRegisterRequest.requiredCapability,
            String(describing: AgentInventoryProviderChangedRequest.self):
                AgentInventoryProviderChangedRequest.requiredCapability,
            String(describing: AppsProviderResultRequest.self): AppsProviderResultRequest.requiredCapability,
            String(describing: AppsRunRequest.self): AppsRunRequest.requiredCapability,
            String(describing: AppsLinkChangedRequest.self): AppsLinkChangedRequest.requiredCapability,
            String(describing: AppsTerminalLinksRequest.self): AppsTerminalLinksRequest.requiredCapability,
        ]
        for (type, gate) in gates.sorted(by: { $0.key < $1.key }) {
            let expected: String? = Self.capabilities[type] ?? nil
            #expect(gate == expected, "\(type)")
        }
    }

    /// Every key a golden sends is a request field of its command in cmux-tui/spec/sdk-schema.json, and the
    /// command is one the macOS app calls, so RequestEmitter generates a type with each of these members.
    @Test func sendsOnlySchemaFields() throws {
        let schema = try JSONDecoder().decode(
            JSONValue.self, from: Data(contentsOf: Self.repositoryRoot().appendingPathComponent("cmux-tui/spec/sdk-schema.json"))
        )
        guard case .object(let document) = schema, case .object(let commands)? = document["commands"] else {
            Issue.record("sdk-schema.json has no commands")
            return
        }
        for golden in Self.goldens {
            guard case .object(let command)? = commands[golden.command],
                  case .array(let clients)? = command["clients"], clients.contains(.string("macos")),
                  case .object(let request)? = command["request"], case .object(let fields)? = request["fields"] else {
                Issue.record("\(golden.name): \(golden.command) is not a macos command of sdk-schema.json")
                continue
            }
            let extra = Set(golden.fields.keys).subtracting(["id", "cmd"]).subtracting(fields.keys)
            #expect(extra.isEmpty, "\(golden.name): not schema fields of \(golden.command): \(extra.sorted())")
        }
    }

    /// Every request type declared in Sources/CmuxNextDaemon/Requests/Apps has a golden. The list is read
    /// from the source, so a type added there, or a further type of one wire command, needs one.
    @Test func everyAppsRequestTypeHasAGolden() throws {
        let directory = try Self.repositoryRoot()
            .appendingPathComponent("Packages/macOS/CmuxNext/Sources/CmuxNextDaemon/Requests/Apps")
        let declaration = try NSRegularExpression(
            pattern: #"\bstruct\s+(\w+)\s*:[^{]*\b(?:DaemonRequest|TerminalSpawningRequest)\b"#
        )
        var declared: Set<String> = []
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        for file in files where file.pathExtension == "swift" {
            let source = try String(contentsOf: file, encoding: .utf8)
            for match in declaration.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
                if let name = Range(match.range(at: 1), in: source) { declared.insert(String(source[name])) }
            }
        }
        // When the migration deletes these structs, this set must come from the generated apps types
        // instead: an empty directory does not pass as "every type has a golden".
        try #require(!declared.isEmpty, "no DaemonRequest type in \(directory.path)")
        let covered = Set(Self.goldens.map(\.type))
        #expect(declared.subtracting(covered).isEmpty, "no golden: \(declared.subtracting(covered).sorted())")
        #expect(covered.subtracting(declared).isEmpty, "not in the directory: \(covered.subtracting(declared).sorted())")
    }

    private static func repositoryRoot() throws -> URL {
        var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: root.appendingPathComponent("cmux-tui/spec").path) {
            let parent = root.deletingLastPathComponent()
            try #require(parent.path != root.path, "no cmux-tui/spec above \(#filePath)")
            root = parent
        }
        return root
    }
}
