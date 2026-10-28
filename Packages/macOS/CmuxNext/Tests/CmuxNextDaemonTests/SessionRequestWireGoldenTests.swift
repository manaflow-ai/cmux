import Foundation
import Testing
@testable import CmuxNextDaemon

/// The wire golden of every request in Sources/CmuxNextDaemon/Requests/Session: the
/// line each one sends today, compared as JSON (key order does not count). The migration to the
/// generated `<Name>Request` types (CmuxNextWireGen RequestEmitter) must send the same lines; the
/// generated coder writes each member under its schema wire name, so a golden that holds here and
/// after the migration proves the bytes did not change.
///
/// Two commands have two hand-written types each, and one generated type after the migration:
/// `client-hello` (step 1 `{role, install_id?, page?}`, step 2 `{install_id, proof}`) and
/// `page-credential` (the app's own `{}` and the scoped `{page}`). The goldens pin both lines of each.
///
/// No member of this directory holds caller-authored keys (WireKeyInventory.dictionaryFields): the
/// one map of these commands, `set-default-colors.palette`, is a schema field the app does not send.
struct SessionRequestWireGoldenTests {
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

    static let goldens: [Golden] = [
        Golden("browser-host-provider", BrowserHostProviderRequest(), [:]),
        Golden("client-hello main", ClientHelloRequest(role: .main), ["role": .string("main")]),
        // A main connection never names a page: the init drops it.
        Golden("client-hello main with an install id",
               ClientHelloRequest(role: .main, installID: "inst-1", page: "history"),
               ["role": .string("main"), "install_id": .string("inst-1")]),
        // A page relay never carries the install id: the init drops it.
        Golden("client-hello page relay",
               ClientHelloRequest(role: .pageRelay, installID: "inst-1", page: "history"),
               ["role": .string("page_relay"), "page": .string("history")]),
        Golden("client-hello proof", ClientHelloProofRequest(installID: "inst-1", proof: "sig-1"),
               ["install_id": .string("inst-1"), "proof": .string("sig-1")]),
        Golden("shutdown-daemon", ShutdownDaemonRequest(pid: 42, generation: DaemonGeneration(rawValue: "gen-1")),
               ["pid": .number(42), "generation": .string("gen-1")]),
        Golden("shutdown-daemon with every field",
               ShutdownDaemonRequest(pid: 42, generation: DaemonGeneration(rawValue: "gen-1"), force: true,
                                     endTerminals: true, keepLayout: false),
               ["pid": .number(42), "generation": .string("gen-1"), "force": .bool(true),
                "end_terminals": .bool(true), "keep_layout": .bool(false)]),
        Golden("set-default-colors without colors", SetDefaultColorsRequest(), [:]),
        Golden("set-default-colors", SetDefaultColorsRequest(fg: "#112233", bg: "#445566", cursor: "#778899"),
               ["fg": .string("#112233"), "bg": .string("#445566"), "cursor": .string("#778899")]),
        Golden("identify", IdentifyRequest(), [:]),
        Golden("identify with machine metadata", IdentifyRequest(machineMetadata: true),
               ["machine_metadata": .bool(true)]),
        // `kind` defaults to "frontend", so the default request is not empty.
        Golden("set-client-info", SetClientInfoRequest(), ["kind": .string("frontend")]),
        Golden("set-client-info without a kind", SetClientInfoRequest(kind: nil), [:]),
        Golden("set-client-info with every field",
               SetClientInfoRequest(name: "cmux", kind: "frontend", capabilities: ["a-v1", "b-v1"],
                                    deviceKind: "mac", deviceName: "Studio"),
               ["name": .string("cmux"), "kind": .string("frontend"),
                "capabilities": .array([.string("a-v1"), .string("b-v1")]), "device_kind": .string("mac"),
                "device_name": .string("Studio")]),
        Golden("page-credential", PageCredentialRequest(), [:]),
        Golden("page-credential scoped", ScopedPageCredentialRequest(page: "home-channels"),
               ["page": .string("home-channels")]),
        // `tree_events` is always sent: the app asks for deltas, the schema's default is coarse.
        Golden("subscribe", SubscribeRequest(), ["tree_events": .string("deltas")]),
        Golden("subscribe with every field", SubscribeRequest(treeEvents: .coarse, surface: SurfaceID(rawValue: 7)),
               ["tree_events": .string("coarse"), "surface": .number(7)]),
        Golden("list-workspaces", ListWorkspacesRequest(), [:]),
        Golden("ws-listen", WsListenRequest(allowOrigin: nil), [:]),
        Golden("ws-listen with one origin", WsListenRequest(allowOrigin: "https://a.test"),
               ["allow_origin": .string("https://a.test")]),
        Golden("ws-listen with origins", WsListenRequest(allowOrigins: ["https://a.test", "https://b.test"]),
               ["allow_origins": .array([.string("https://a.test"), .string("https://b.test")])]),
    ]

    @Test(arguments: goldens)
    func sendsItsGoldenLine(_ golden: Golden) throws {
        let line = try JSONDecoder().decode(JSONValue.self, from: golden.encode())
        #expect(line == .object(golden.fields))
    }

    /// Every key a golden sends is a request field of its command in cmux-tui/spec/sdk-schema.json, and the
    /// command is one the macOS app calls, so RequestEmitter generates a type with each of these members.
    @Test func sendsOnlySchemaFields() throws {
        let commands = try Self.schemaCommands()
        for golden in Self.goldens {
            guard case .object(let command)? = commands[golden.command] else {
                Issue.record("\(golden.command) is not in sdk-schema.json")
                continue
            }
            guard case .array(let clients)? = command["clients"], clients.contains(.string("macos")) else {
                Issue.record("\(golden.command) is not a macos command")
                continue
            }
            guard case .object(let request)? = command["request"], case .object(let fields)? = request["fields"] else {
                Issue.record("\(golden.command) has no request fields")
                continue
            }
            let extra = Set(golden.fields.keys).subtracting(["id", "cmd"]).subtracting(fields.keys)
            #expect(extra.isEmpty, "\(golden.name): not schema fields of \(golden.command): \(extra.sorted())")
        }
    }

    /// Every request type of the directory has a golden, both types of `client-hello` and of
    /// `page-credential` included.
    @Test func everySessionRequestHasAGolden() {
        let covered = Set(Self.goldens.map(\.type))
        let types: Set = [
            String(describing: BrowserHostProviderRequest.self), String(describing: ClientHelloRequest.self),
            String(describing: ClientHelloProofRequest.self), String(describing: ShutdownDaemonRequest.self),
            String(describing: SetDefaultColorsRequest.self), String(describing: IdentifyRequest.self),
            String(describing: SetClientInfoRequest.self), String(describing: PageCredentialRequest.self),
            String(describing: ScopedPageCredentialRequest.self), String(describing: SubscribeRequest.self),
            String(describing: ListWorkspacesRequest.self), String(describing: WsListenRequest.self),
        ]
        #expect(types.subtracting(covered).isEmpty, "no golden: \(types.subtracting(covered).sorted())")
    }

    /// `$.commands` of cmux-tui/spec/sdk-schema.json.
    private static func schemaCommands() throws -> [String: JSONValue] {
        var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: root.appendingPathComponent("cmux-tui/spec").path) {
            let parent = root.deletingLastPathComponent()
            try #require(parent.path != root.path, "no cmux-tui/spec above \(#filePath)")
            root = parent
        }
        let data = try Data(contentsOf: root.appendingPathComponent("cmux-tui/spec/sdk-schema.json"))
        guard case .object(let schema) = try JSONDecoder().decode(JSONValue.self, from: data),
              case .object(let commands)? = schema["commands"] else { return [:] }
        return commands
    }
}
