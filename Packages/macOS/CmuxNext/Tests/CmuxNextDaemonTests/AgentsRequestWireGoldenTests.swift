import Foundation
import Testing
@testable import CmuxNextDaemon

/// The wire golden of every request in Sources/CmuxNextDaemon/Requests/Agents: the line
/// each one sends today, compared as JSON (key order does not count), with the capability it is gated
/// on and whether it waits for a terminal spawn. The migration to the generated `<Name>Request` types
/// (CmuxNextWireGen RequestEmitter) must keep these goldens green: the generated coder writes each
/// member under its schema wire name, so a golden that holds here and after the migration proves the
/// bytes did not change.
///
/// No Agents field holds caller-authored keys (WireKeyInventory.dictionaryFields lists none here): the
/// snake-case strategy and the generated CodingKeys write the same names, so every golden stays byte
/// for byte.
///
/// Two wire commands are sent by more than one type, each with its own capability: `agent-inventory`
/// (the unfenced read and the owner-fenced read) and `agent-inventory-watch` (enable, conditional
/// retire, enable with an admission receipt). Each golden is therefore keyed by its Swift type, and its
/// capability is part of the golden: an older daemon must still receive none of these requests.
///
/// Known gap (this file and the Apps, Conversations and TerminalIO goldens): nothing requires a golden for a new
/// request type. Swift cannot list the types that conform to `DaemonRequest` at run time, and the live registries
/// list wire commands, not Swift types (`DaemonCommandName`'s generated hash table; `MethodTable.schema.methods`,
/// grouped by family), so a second type of one command, or a type a family gains, has no runtime list to check
/// against. A test that read the Swift sources for these types was removed: the repo's test policy forbids
/// reading sources. A new request type adds its golden here by hand.
struct AgentsRequestWireGoldenTests {
    /// One request's expected line (`id` and `cmd` included) and gating.
    struct Golden: Sendable, CustomTestStringConvertible {
        let name: String
        /// The request's Swift type: one wire command can have several.
        let type: String
        let command: String
        let encode: @Sendable () throws -> Data
        let line: [String: JSONValue]
        let requiredCapability: String?
        let expectedCapability: String?
        let spawnsTerminal: Bool
        let expectedSpawnsTerminal: Bool

        init<R: DaemonRequest>(_ name: String, _ request: R, _ fields: [String: JSONValue],
                               capability: String? = nil, spawnsTerminal: Bool = false) {
            self.name = name
            type = String(describing: R.self)
            command = R.command
            encode = { try WireCoding.encodeRequest(request, id: 1) }
            var line = fields
            line["id"] = .number(1)
            line["cmd"] = .string(R.command)
            self.line = line
            requiredCapability = R.requiredCapability
            expectedCapability = capability
            self.spawnsTerminal = request is any TerminalSpawningRequest
            expectedSpawnsTerminal = spawnsTerminal
        }

        var testDescription: String { name }
    }

    private static let surface = SurfaceID(rawValue: 7)
    private static let machine: ResourceID = "machine_0123456789abcdef0123456789abcdef"
    private static let session: ResourceID = "session_0123456789abcdef"

    static let goldens: [Golden] = [
        Golden("list-agents", ListAgentsRequest(), [:]),
        Golden("list-agents filtered", ListAgentsRequest(surface: surface, state: .working),
               ["surface": .number(7), "state": .string("working")]),
        Golden("agent-inventory", AgentInventoryRequest(), [:], capability: "agent-inventory-v1"),
        Golden("agent-inventory fenced to its owner", MachineAgentInventoryRequest(expectedMachineID: machine),
               ["expected_machine_id": .string(machine.rawValue)], capability: "agent-inventory-owner-v1"),
        Golden("agent-inventory-refresh", MachineAgentInventoryRefreshRequest(expectedMachineID: machine),
               ["expected_machine_id": .string(machine.rawValue)], capability: "agent-inventory-refresh-v1"),
        Golden("agent-inventory-watch enable", MachineAgentInventoryWatchRequest(expectedMachineID: machine),
               ["expected_machine_id": .string(machine.rawValue), "enabled": .bool(true)],
               capability: "agent-inventory-watch-fence-v1"),
        Golden("agent-inventory-watch retire",
               MachineAgentInventoryUnwatchRequest(expectedMachineID: machine, expectedWatchID: "watch-1"),
               ["expected_machine_id": .string(machine.rawValue), "expected_watch_id": .string("watch-1"),
                "enabled": .bool(false)],
               capability: "agent-inventory-watch-fence-v1"),
        Golden("agent-inventory-watch enable with an admission receipt",
               MachineAgentInventoryAdmissionRequest(expectedMachineID: machine),
               ["expected_machine_id": .string(machine.rawValue), "enabled": .bool(true),
                "admission_receipt": .bool(true)],
               capability: "agent-inventory-watch-admission-v1"),
        Golden("agent-cli-update-job",
               MachineAgentCLIUpdateJobRequest(expectedMachineID: machine, expectedSessionID: session, cli: .codex,
                                               idempotencyKey: "key-1"),
               ["expected_machine_id": .string(machine.rawValue), "expected_session_id": .string(session.rawValue),
                "cli": .string("codex"), "idempotency_key": .string("key-1")],
               capability: "agent-cli-update-job-v1", spawnsTerminal: true),
        Golden("feed-local-list", FeedLocalListRequest(), [:], capability: "feed-local-owner-v1"),
        Golden("feed-local-list with every field", FeedLocalListRequest(state: .handingOff, terminalId: "t1", unread: true),
               ["state": .string("handing_off"), "terminal_id": .string("t1"), "unread": .bool(true)],
               capability: "feed-local-owner-v1"),
        Golden("feed-local-handoff-begin", FeedLocalHandoffBeginRequest(item: "item-1"), ["item": .string("item-1")],
               capability: "feed-local-owner-v1"),
        Golden("feed-local-handoff-done", FeedLocalHandoffDoneRequest(item: "item-1", home: "cloud"),
               ["item": .string("item-1"), "home": .string("cloud")], capability: "feed-local-owner-v1"),
        // `body` is not optional: an empty body is still sent.
        Golden("notify", NotifyRequest(title: "Build done"), ["title": .string("Build done"), "body": .string("")]),
        Golden("notify with every field",
               NotifyRequest(title: "Build done", body: "12 tests", level: .warning, surface: surface, source: "agent"),
               ["title": .string("Build done"), "body": .string("12 tests"), "level": .string("warning"),
                "surface": .number(7), "source": .string("agent")]),
        Golden("ack-tab-notifications", AckTabNotificationsRequest(surface: surface), ["surface": .number(7)],
               capability: "notification-ack-v1"),
        Golden("list-notifications", ListNotificationsRequest(), [:], capability: "notification-ack-v1"),
        Golden("list-notifications limited", ListNotificationsRequest(limit: 50), ["limit": .number(50)],
               capability: "notification-ack-v1"),
        Golden("report-agent", ReportAgentRequest(surface: surface, state: .blocked),
               ["surface": .number(7), "state": .string("blocked"), "source": .string("hook")]),
        Golden("report-agent with a session",
               ReportAgentRequest(surface: surface, state: .done, source: "socket", session: "sess-1"),
               ["surface": .number(7), "state": .string("done"), "source": .string("socket"), "session": .string("sess-1")]),
    ]

    /// Commands of this directory that cmux-tui/spec/sdk-schema.json does not describe yet, with the
    /// task that adds them; RequestEmitter generates no type for a command before that task lands.
    static let awaitingSchema: [String: String] = [
        "agent-inventory": "p05-ipc-015",
        "agent-inventory-refresh": "p05-ipc-015",
        "agent-inventory-watch": "p05-ipc-015",
    ]

    @Test(arguments: goldens)
    func sendsItsGoldenLine(_ golden: Golden) throws {
        let line = try JSONDecoder().decode(JSONValue.self, from: golden.encode())
        #expect(line == .object(golden.line))
    }

    /// The capability each type is refused without, and the spawn deadline, stay with the request.
    @Test(arguments: goldens)
    func keepsItsGating(_ golden: Golden) {
        #expect(golden.requiredCapability == golden.expectedCapability)
        #expect(golden.spawnsTerminal == golden.expectedSpawnsTerminal)
    }

    /// Every key a golden sends is a request field of its command in cmux-tui/spec/sdk-schema.json, and the
    /// command is one the macOS app calls, so RequestEmitter generates a type with each of these members.
    /// A command still awaiting its schema task is skipped until it is in the schema, then checked too.
    @Test func sendsOnlySchemaFields() throws {
        let commands = try Self.schemaCommands()
        for golden in Self.goldens {
            guard case .object(let command)? = commands[golden.command] else {
                #expect(Self.awaitingSchema[golden.command] != nil, "\(golden.command) is not in sdk-schema.json")
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
            let extra = Set(golden.line.keys).subtracting(["id", "cmd"]).subtracting(fields.keys)
            #expect(extra.isEmpty, "\(golden.name): not schema fields of \(golden.command): \(extra.sorted())")
        }
    }

    // Schema ----------------------------------------------------------------

    /// `$.commands` of cmux-tui/spec/sdk-schema.json.
    private static func schemaCommands() throws -> [String: JSONValue] {
        let data = try Data(contentsOf: repositoryRoot().appendingPathComponent("cmux-tui/spec/sdk-schema.json"))
        guard case .object(let schema) = try JSONDecoder().decode(JSONValue.self, from: data),
              case .object(let commands)? = schema["commands"] else { return [:] }
        return commands
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
