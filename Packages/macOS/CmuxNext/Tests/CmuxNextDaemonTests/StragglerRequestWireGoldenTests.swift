import Foundation
import Testing
@testable import CmuxNextDaemon

/// The wire golden of every request p05-ipc-043 migrates in CmuxNextDaemon: Connection/
/// (AgentCLIIntentLedger, AgentCLIJobCarrier, HomeWorkspaceClient), Loopback/, Chief/ and Tree/.
/// It pins the line each one sends today, compared as JSON (key order does not count). The
/// migration to the generated `<Name>Request` types (CmuxNextWireGen RequestEmitter) must send the
/// same lines; the generated coder writes each member under its schema wire name, so a golden that
/// holds here and after the migration proves the bytes did not change. CmuxNextApp's
/// `machine-listening-tcp` has its golden in CmuxNextAppTests (MachineListeningTCPRequestWireGoldenTests).
///
/// Dictionary-valued field (WireKeyInventory.dictionaryFields), whose keys neither coder renames:
/// `chief-inspect.query` (a string map). The golden pins that its keys go out as given.
///
/// Explicit nulls the generated types must keep: `bind-conversation-tab-session.expected_session`
/// (required and nullable: null is "no session yet") and `set-personal-terminal.theme` (null clears).
struct StragglerRequestWireGoldenTests {
    /// One request's expected line, `id` and `cmd` included.
    struct Golden: Sendable, CustomTestStringConvertible {
        let name: String
        let encode: @Sendable () throws -> Data
        let command: String
        let capability: String?
        let fields: [String: JSONValue]

        init<R: DaemonRequest>(_ name: String, _ request: R, _ fields: [String: JSONValue]) {
            self.init(name, fields) { request }
        }

        /// A request whose construction validates its input (an intent, a receipt) and so throws.
        init<R: DaemonRequest>(_ name: String, _ fields: [String: JSONValue], _ request: @escaping @Sendable () throws -> R) {
            self.name = name
            encode = { try WireCoding.encodeRequest(request(), id: 1) }
            command = R.command
            capability = R.requiredCapability
            var line = fields
            line["id"] = .number(1)
            line["cmd"] = .string(R.command)
            self.fields = line
        }

        var testDescription: String { name }
    }

    /// The map and `JsonValue` request fields of these commands: documents whose keys the caller writes.
    static let dictionaryFields: Set = ["chief-inspect.query"]

    private static let machine: ResourceID = "machine_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    private static let session: ResourceID = "session_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    private static let owner: ResourceID = "machine_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    private static let ownerSession: ResourceID = "session_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

    static let goldens: [Golden] = agentCLIGoldens + conversationTabGoldens + loopbackGoldens + chiefGoldens
        + personalTerminalGoldens

    /// The recovery ledger and the job carrier: both owner conditions on every line.
    private static let agentCLIGoldens: [Golden] = {
        let conditions: [String: JSONValue] = [
            "expected_machine_id": .string(machine.rawValue), "expected_session_id": .string(session.rawValue),
        ]
        func with(_ fields: [String: JSONValue]) -> [String: JSONValue] { conditions.merging(fields) { _, new in new } }
        let intent = { @Sendable () throws -> AgentCLIUpdateIntent in
            try AgentCLIUpdateIntent(key: "original-child", rootKey: "original-root", machine: owner,
                                     session: ownerSession, cli: .claude, profiles: ["work-profile"])
        }
        let intentDocument = JSONValue.object([
            "key": .string("original-child"), "root_key": .string("original-root"), "machine": .string(owner.rawValue),
            "session": .string(ownerSession.rawValue), "cli": .string("claude"), "profiles": .array([.string("work-profile")]),
        ])
        let path: [String: JSONValue] = [
            "kind": .string("terminal"), "workspace_id": .string("ws_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"),
            "screen_id": .string("screen_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"),
            "pane_id": .string("pane_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"),
            "tab_id": .string("tab_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"),
            "terminal_id": .string("term_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"),
        ]
        // The revision is decimal text, so a UInt64 above 2^53 survives every JSON reader.
        let receiptDocument: [String: JSONValue] = [
            "machine": .string(owner.rawValue), "session": .string(ownerSession.rawValue), "cli": .string("claude"),
            "revision": .string("18446744073709551615"), "replayed": .bool(true), "path": .object(path),
        ]
        let receipt = { @Sendable () throws -> AgentCLIJobReceipt in
            try JSONDecoder().decode(AgentCLIJobReceipt.self, from: JSONEncoder().encode(JSONValue.object(receiptDocument)))
        }
        return [
            Golden("agent-cli-intents-record", with(["intents": .array([intentDocument])])) {
                try AgentCLIIntentLedger.Record(expectedMachineID: machine, expectedSessionID: session, intents: [intent()])
            },
            Golden("agent-cli-intents-list",
                   AgentCLIIntentLedger.List(expectedMachineID: machine, expectedSessionID: session), conditions),
            Golden("agent-cli-intents-settle",
                   AgentCLIIntentLedger.Settle(expectedMachineID: machine, expectedSessionID: session,
                                               keys: ["original-child", "original-root"]),
                   with(["keys": .array([.string("original-child"), .string("original-root")])])),
            Golden("agent-cli-intents-attach", with(["key": .string("original-child"), "receipt": .object(receiptDocument)])) {
                try AgentCLIIntentLedger.Attach(expectedMachineID: machine, expectedSessionID: session,
                                                key: "original-child", receipt: receipt())
            },
            Golden("agent-cli-update-job-resolve",
                   AgentCLIJobCarrier.Resolve(expectedMachineID: machine, expectedSessionID: session, cli: "claude",
                                              idempotencyKey: "original-job-key"),
                   with(["cli": .string("claude"), "idempotency_key": .string("original-job-key")])),
        ]
    }()

    /// `new-conversation-tab` through each of its initializers, and `bind-conversation-tab-session`.
    private static let conversationTabGoldens: [Golden] = {
        let chat = AgentSessionRef(host: "install:mac", hostName: "Mac", session: "s-1", harness: "claude")
        var split = NewConversationTabRequest(page: "settings", pane: 3)
        split.split = ConversationTabSplit(direction: .right, paneID: "pane_c", splitID: "split_c")
        var oldSplit = NewConversationTabRequest(page: "settings", pane: 3)
        oldSplit.split = ConversationTabSplit(direction: .down, paneID: "pane_c", splitID: nil)
        return [
            Golden("new-conversation-tab conversation", NewConversationTabRequest(conversation: "c-1"),
                   ["conversation": .string("c-1"), "owner": .string("local")]),
            Golden("new-conversation-tab conversation with every field",
                   NewConversationTabRequest(conversation: "c-1", owner: "cloud", pane: 7, origin: "palette", mutationID: "m-1"),
                   ["conversation": .string("c-1"), "owner": .string("cloud"), "pane": .number(7),
                    "origin": .string("palette"), "mutation_id": .string("m-1")]),
            Golden("new-conversation-tab conversation in a workspace",
                   NewConversationTabRequest(conversation: "c-1", workspace: 2),
                   ["conversation": .string("c-1"), "owner": .string("local"), "workspace": .number(2)]),
            Golden("new-conversation-tab agent session in a pane",
                   NewConversationTabRequest(agentSession: chat, pane: 3, origin: "home", mutationID: "m-2",
                                             transaction: ClientTransactionID(rawValue: "t-1")),
                   ["agent_session": .object(["host": .string("install:mac"), "host_name": .string("Mac"),
                                              "session": .string("s-1"), "harness": .string("claude")]),
                    "pane": .number(3), "origin": .string("home"), "mutation_id": .string("m-2"),
                    "transaction": .string("t-1")]),
            Golden("new-conversation-tab new agent chat in a workspace",
                   NewConversationTabRequest(agentSession: AgentSessionRef(host: "install:mac"), workspace: 2),
                   ["agent_session": .object(["host": .string("install:mac")]), "workspace": .number(2)]),
            Golden("new-conversation-tab page in a pane",
                   NewConversationTabRequest(page: "settings", route: "general", pane: 3, origin: "palette",
                                             mutationID: "m-3", transaction: ClientTransactionID(rawValue: "t-2")),
                   ["page": .string("settings"), "route": .string("general"), "pane": .number(3),
                    "origin": .string("palette"), "mutation_id": .string("m-3"), "transaction": .string("t-2")]),
            Golden("new-conversation-tab page in a workspace",
                   NewConversationTabRequest(page: "home", workspace: 2, origin: "dock", mutationID: "m-4"),
                   ["page": .string("home"), "workspace": .number(2), "origin": .string("dock"),
                    "mutation_id": .string("m-4")]),
            Golden("new-conversation-tab split", split,
                   ["page": .string("settings"), "pane": .number(3),
                    "split": .object(["direction": .string("right"), "pane_id": .string("pane_c"),
                                      "split_id": .string("split_c")])]),
            Golden("new-conversation-tab split without a split id", oldSplit,
                   ["page": .string("settings"), "pane": .number(3),
                    "split": .object(["direction": .string("down"), "pane_id": .string("pane_c")])]),
            Golden("bind-conversation-tab-session first session",
                   BindConversationTabSessionRequest(surface: 9, session: "s-1"),
                   ["surface": .number(9), "session": .string("s-1"), "expected_session": .null]),
            Golden("bind-conversation-tab-session with every field",
                   BindConversationTabSessionRequest(surface: 9, session: "s-2", expectedSession: "s-1", harness: "codex"),
                   ["surface": .number(9), "session": .string("s-2"), "expected_session": .string("s-1"),
                    "harness": .string("codex")]),
        ]
    }()

    /// Loopback/: the browser runtime and the loopback stream.
    private static let loopbackGoldens: [Golden] = [
        Golden("browser-runtime-status", BrowserRuntimeStatusRequest(), [:]),
        Golden("browser-runtime-start", BrowserRuntimeStartRequest(), [:]),
        Golden("browser-runtime-start with a url", BrowserRuntimeStartRequest(url: "http://localhost:3000/"),
               ["url": .string("http://localhost:3000/")]),
        Golden("browser-runtime-stop", BrowserRuntimeStopRequest(runtime: 4), ["runtime": .number(4)]),
        Golden("loopback-open", LoopbackOpenRequest(stream: 11, host: "127.0.0.1", port: 5173, window: 262_144),
               ["stream": .number(11), "host": .string("127.0.0.1"), "port": .number(5173), "window": .number(262_144)]),
    ]

    /// `query` is always sent, empty too; its keys go out as given (camelCase included).
    private static let chiefGoldens: [Golden] = [
        Golden("chief-inspect", ChiefInspectRequest(path: "/api/memories", query: [:]),
               ["path": .string("/api/memories"), "query": .object([:])]),
        Golden("chief-inspect with a query",
               ChiefInspectRequest(path: "/api/memories", query: ["limit": "5", "sinceMs": "10"]),
               ["path": .string("/api/memories"), "query": .object(["limit": .string("5"), "sinceMs": .string("10")])]),
    ]

    private static let personalTerminalGoldens: [Golden] = [
        Golden("set-personal-terminal", SetPersonalTerminalRequest(sessionID: "s-1", terminalKey: "k-1", theme: "Dracula"),
               ["session_id": .string("s-1"), "terminal_key": .string("k-1"), "theme": .string("Dracula")]),
        Golden("set-personal-terminal clear", SetPersonalTerminalRequest(sessionID: "s-1", terminalKey: "k-1", theme: nil),
               ["session_id": .string("s-1"), "terminal_key": .string("k-1"), "theme": .null]),
    ]

    @Test(arguments: goldens)
    func sendsItsGoldenLine(_ golden: Golden) throws {
        let line = try JSONDecoder().decode(JSONValue.self, from: golden.encode())
        #expect(line == .object(golden.fields))
    }

    /// Every sent key is a request field of its command in cmux-tui/spec/sdk-schema.json, every
    /// required field is sent, and the command lists the macos client, so RequestEmitter generates
    /// a type with each of these members.
    @Test func sendsSchemaFields() throws {
        let commands = try Self.schemaCommands()
        for golden in Self.goldens {
            let fields = try Self.requestFields(golden.command, in: commands)
            let sent = Set(golden.fields.keys).subtracting(["id", "cmd"])
            let extra = sent.subtracting(fields.keys)
            #expect(extra.isEmpty, "\(golden.name): not schema fields of \(golden.command): \(extra.sorted())")
            let required = fields.compactMap { entry -> String? in
                guard case .object(let spec) = entry.value, spec["presence"] == JSONValue.string("required") else {
                    return nil
                }
                return entry.key
            }
            let missing = Set(required).subtracting(sent)
            #expect(missing.isEmpty, "\(golden.name): required fields of \(golden.command) not sent: \(missing.sorted())")
        }
    }

    /// A field a golden sends as null is nullable in the schema, so the generated type keeps the null.
    @Test func sentNullsAreNullable() throws {
        let commands = try Self.schemaCommands()
        var nulls: Set<String> = []
        for golden in Self.goldens {
            let fields = try Self.requestFields(golden.command, in: commands)
            for (name, value) in golden.fields where value == .null {
                nulls.insert("\(golden.command).\(name)")
                guard case .object(let spec)? = fields[name] else { continue }
                #expect(spec["nullable"] == JSONValue.bool(true), "\(golden.name): \(name) is not nullable")
            }
        }
        #expect(nulls == ["bind-conversation-tab-session.expected_session", "set-personal-terminal.theme"])
    }

    /// The map and `JsonValue` request fields of these commands are exactly the listed dictionary
    /// fields, so no document the generated type takes as given is left out of the list.
    @Test func dictionaryFieldsAreTheMapFields() throws {
        let commands = try Self.schemaCommands()
        var documents: Set<String> = []
        for command in Set(Self.goldens.map(\.command)) {
            for (name, spec) in try Self.requestFields(command, in: commands) {
                guard case .object(let field) = spec, case .object(let type)? = field["type"] else { continue }
                let isMap = type["kind"] == JSONValue.string("map")
                let isDocument = type["kind"] == JSONValue.string("ref") && type["name"] == JSONValue.string("JsonValue")
                if isMap || isDocument { documents.insert("\(command).\(name)") }
            }
        }
        #expect(documents == Self.dictionaryFields)
    }

    /// A hand-written type that gates on a capability gates on the schema's one. The generated
    /// types take every command's capability from the schema (MethodTable), so the commands
    /// written here without one become gated on theirs; this pins which those are.
    @Test func capabilitiesAgreeWithTheSchema() throws {
        let commands = try Self.schemaCommands()
        var ungated: Set<String> = []
        for golden in Self.goldens {
            guard case .object(let spec)? = commands[golden.command] else { throw SchemaShapeError.missing(golden.command) }
            guard let capability = golden.capability else {
                ungated.insert(golden.command)
                continue
            }
            #expect(spec["capability"] == JSONValue.string(capability), "\(golden.command): \(capability)")
        }
        #expect(ungated == [
            "agent-cli-intents-record", "agent-cli-intents-list", "agent-cli-intents-settle", "agent-cli-intents-attach",
            "bind-conversation-tab-session", "chief-inspect",
        ])
    }

    /// Every request type of the task's CmuxNextDaemon files has a golden.
    @Test func everyStragglerCommandHasAGolden() {
        let covered = Set(Self.goldens.map(\.command))
        let commands: Set = [
            AgentCLIIntentLedger.Record.command, AgentCLIIntentLedger.List.command, AgentCLIIntentLedger.Settle.command,
            AgentCLIIntentLedger.Attach.command, AgentCLIJobCarrier.Resolve.command, NewConversationTabRequest.command,
            BindConversationTabSessionRequest.command, BrowserRuntimeStatusRequest.command,
            BrowserRuntimeStartRequest.command, BrowserRuntimeStopRequest.command, LoopbackOpenRequest.command,
            ChiefInspectRequest.command, SetPersonalTerminalRequest.command,
        ]
        #expect(commands.count == 13)
        #expect(commands.subtracting(covered).isEmpty)
    }

    /// The request fields of `command`, which must be a macos command of the schema.
    private static func requestFields(_ command: String, in commands: [String: JSONValue]) throws -> [String: JSONValue] {
        guard case .object(let spec)? = commands[command] else { throw SchemaShapeError.missing(command) }
        guard case .array(let clients)? = spec["clients"], clients.contains(.string("macos")) else {
            throw SchemaShapeError.notMacOS(command)
        }
        guard case .object(let request)? = spec["request"], case .object(let fields)? = request["fields"] else {
            return [:]
        }
        return fields
    }

    enum SchemaShapeError: Error {
        case missing(String)
        case notMacOS(String)
        case noSchema
    }

    /// `$.commands` of cmux-tui/spec/sdk-schema.json.
    private static func schemaCommands() throws -> [String: JSONValue] {
        var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: root.appendingPathComponent("cmux-tui/spec").path) {
            let parent = root.deletingLastPathComponent()
            guard parent.path != root.path else { throw SchemaShapeError.noSchema }
            root = parent
        }
        let data = try Data(contentsOf: root.appendingPathComponent("cmux-tui/spec/sdk-schema.json"))
        guard case .object(let schema) = try JSONDecoder().decode(JSONValue.self, from: data),
              case .object(let commands)? = schema["commands"] else { throw SchemaShapeError.noSchema }
        return commands
    }
}
