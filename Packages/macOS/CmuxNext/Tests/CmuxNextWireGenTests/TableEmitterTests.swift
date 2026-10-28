import Foundation
import Testing
@testable import CmuxNextWireGen

private func fixtureData(_ file: String) throws -> Data {
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<6 { root.deleteLastPathComponent() }
    return try Data(contentsOf: root.appendingPathComponent("cmux-tui/spec/fixtures/ipc-method-tables/\(file)"))
}

private func json(_ text: String) throws -> SchemaJSON {
    try JSONDecoder().decode(SchemaJSON.self, from: Data(text.utf8))
}

/// The schema reader and table emitter behind `MethodTable.schema`:
/// they read cmux-tui/spec/fixtures/ipc-method-tables the way
/// the Rust build script does, refuse what the tables cannot encode with its
/// JSON path, and write the same bytes every run.
@Suite struct TableEmitterTests {
    private static func fixture() throws -> MethodTableSchema {
        try MethodTableSchema(sdkSchema: fixtureData("sdk-schema.json"),
                              resourceOperations: fixtureData("resource-operations-v2.json"))
    }

    @Test func readsTheFixtureIntoDenseFamilies() throws {
        let schema = try Self.fixture()
        #expect(schema.v12.map(\.id) == [0x01, 0x03])
        #expect(schema.v2.map(\.id) == [0x60, 0x62])
        #expect(schema.events.map(\.id) == [0xC0, 0xC2])

        let terminalIO = try #require(schema.v12.first)
        #expect(terminalIO.name == "terminal-io")
        #expect(terminalIO.slots.map { $0?.name } == ["send", nil, "resize-attached-view", "scroll-surface", "send-binary"])
        let send = try #require(terminalIO.slots[0])
        #expect(send.priority == "input" && send.durability == "memory" && send.urgent && send.streamScoped)
        let binary = try #require(terminalIO.slots[4])
        #expect(binary.binaryLayout == 1 && binary.maxBytes == 65536)
        let scroll = try #require(terminalIO.slots[3])
        #expect(scroll.coalesce == MethodTableSchema.Coalesce(key: ["surface"], additive: ["delta"]))
        #expect(scroll.crossesStreamOK == "Scrolling reads the viewport only.")

        let tabs = schema.v12[1]
        #expect(tabs.slots.map { $0?.name } == ["new-tab", "list-tabs", nil, "close-tab"])
        #expect(tabs.slots[3]?.durability == "replyAfterJournal")
        #expect(tabs.slots[3]?.ordering == "sequence")
        #expect(tabs.slots[1]?.ordering == "independent")

        let history = try #require(schema.v2[1].slots[3])
        #expect(history.name == "workspace.read_history" && history.id == 0x6203 && history.priority == "bulk")
        #expect(schema.events[0].slots.map { $0?.name } == ["output", "size-state"])
        #expect(schema.events[1].slots.map { $0?.name } == ["tab-created", nil, "tab-renamed"])
    }

    /// The app's table holds only `clients: macos` methods (design 3.3); the
    /// Rust tables keep every one (cmux-ipc `methods_table_fixture_lookups`).
    @Test func keepsOnlyTheMacOSClientsMethods() throws {
        let schema = try Self.fixture()
        let names = (schema.v12 + schema.v2).flatMap { $0.slots.compactMap { $0?.name } }
        #expect(!names.contains("tab-inventory") && !names.contains("attach-cli") && !names.contains("agent.attach_cli"))
        // attach-cli held terminal-io's last ordinal and agent.attach_cli agent's: the families end before them.
        #expect(schema.v12.first?.slots.count == 5)
        #expect(schema.v2.first?.slots.map { $0?.name } == ["agent.list", "agent.update"])
        // tab-inventory's ordinal stays free.
        #expect(schema.v12[1].slots[2] == nil)
        // A method with no `clients` is every client's, so it is kept.
        #expect(names.contains("new-tab") && names.contains("workspace.list"))

        let sdk = try MethodTableSchema(sdkSchema: fixtureData("sdk-schema.json"),
                                        resourceOperations: fixtureData("resource-operations-v2.json"),
                                        client: "sdk")
        #expect(sdk.v12[1].slots[2]?.name == "tab-inventory")
        #expect(sdk.v12[0].slots.count == 6)

        // A family whose methods are all another client's is left out.
        let cliOnly = try MethodTableSchema(sdk: json(Self.sdk(
            families: #"{"cli": {"id": 4}, "tabs": {"id": 3}}"#,
            commands: #"{"a": {"method_id": 1024, "priority": "control", "durability": "memory", "clients": ["cli"]}, "#
                + #""b": {"method_id": 768, "priority": "control", "durability": "memory", "clients": ["macos"]}}"#)),
            v2: json(#"{"operations": {}}"#))
        #expect(cliOnly.v12.map(\.id) == [0x03])
    }

    @Test func emitsDenseSpacesAndRows() throws {
        let source = TableEmitter(schema: try Self.fixture()).source()
        #expect(source.contains("public static let schema = MethodTable(v12: schemaV12, v2: schemaV2, events: schemaEvents)"))
        #expect(source.contains(
            "MethodAttributes(id: MethodID(rawValue: 0x0100), name: \"send\", priority: .input, ordering: .sequence, "
                + "durability: .memory, payload: .json, streamScoped: true, crossesStreamOK: nil, maxBytes: nil, "
                + "coalesce: nil, urgent: true),"))
        #expect(source.contains("payload: .binary(layoutVersion: 1)"))
        #expect(source.contains("coalesce: MethodCoalesce(key: [\"surface\"], additive: [\"delta\"])"))
        #expect(source.contains("EventAttributes(id: EventID(rawValue: 0xC001), name: \"size-state\", priority: .control"))
        // One slot per family of each space: 95 v12, 96 v2, 63 event families.
        let v12 = try #require(source.range(of: "private let schemaV12: [MethodTableFamily<MethodAttributes>?] = [\n"))
        let v12Body = source[v12.upperBound...].prefix { $0 != "]" }
        #expect(v12Body.split(separator: "\n").count == 95)
        #expect(v12Body.hasPrefix("    schemaV12Family0x01,\n    nil,\n    schemaV12Family0x03,\n"))
    }

    @Test func emitsTheSameBytesEveryRun() throws {
        let first = TableEmitter(schema: try Self.fixture()).source()
        let second = TableEmitter(schema: try Self.fixture()).source()
        #expect(first == second)
    }

    @Test func literalsCannotEndTheStringOrInterpolate() {
        #expect(TableEmitter.literal("send") == "\"send\"")
        #expect(TableEmitter.literal("a\"b\\(c)") == "\"a\\\"b\\\\(c)\"")
        #expect(TableEmitter.literal("line\nnext é") == "\"line\\u{A}next \\u{E9}\"")
    }

    // Refusals --------------------------------------------------------------

    private static func refused(sdk: String, v2: String = #"{"operations": {}}"#) throws -> String {
        let sdkDocument = try json(sdk)
        let v2Document = try json(v2)
        do {
            _ = try MethodTableSchema(sdk: sdkDocument, v2: v2Document)
        } catch {
            return error.description
        }
        Issue.record("schema was not refused: \(sdk)")
        return ""
    }

    private static func sdk(families: String, commands: String, events: String = "{}") -> String {
        #"{"families": \#(families), "commands": \#(commands), "events": \#(events)}"#
    }

    @Test func refusesADuplicateID() throws {
        let message = try Self.refused(sdk: Self.sdk(
            families: #"{"tabs": {"id": 3}}"#,
            commands: #"{"a": {"method_id": 768, "priority": "control", "durability": "memory"}, "b": {"method_id": 768, "priority": "control", "durability": "memory"}}"#))
        #expect(message.contains("$.commands.b.method_id"), "\(message)")
        #expect(message.contains("also held by \"a\""), "\(message)")
    }

    @Test func refusesAnUndeclaredOrForeignFamily() throws {
        let undeclared = try Self.refused(sdk: Self.sdk(
            families: "{}", commands: #"{"a": {"method_id": 768, "priority": "control", "durability": "memory"}}"#))
        #expect(undeclared.contains("not declared"), "\(undeclared)")

        let foreign = try Self.refused(sdk: Self.sdk(
            families: #"{"ev": {"id": 192}}"#, commands: #"{"a": {"method_id": 49152, "priority": "control", "durability": "memory"}}"#))
        #expect(foreign.contains("outside families 0x01-0x5F"), "\(foreign)")

        let v2InSDK = try Self.refused(sdk: Self.sdk(families: #"{"agent": {"id": 96}}"#, commands: "{}"))
        #expect(v2InSDK.contains("outside this file's family ranges"), "\(v2InSDK)")

        let twice = try Self.refused(sdk: Self.sdk(families: #"{"a": {"id": 3}, "b": {"id": 3}}"#, commands: "{}"))
        #expect(twice.contains("is also family"), "\(twice)")

        let v2 = try Self.refused(
            sdk: Self.sdk(families: "{}", commands: "{}"),
            v2: #"{"families": {"agent": {"id": 96}}, "operations": {"agent.list": {"method_id": 256, "priority": "control", "durability": "memory"}}}"#)
        #expect(v2.hasPrefix("resource-operations-v2.json: $.operations.agent.list.method_id"), "\(v2)")
    }

    @Test func refusesAttributesItCannotEncode() throws {
        let cases: [(command: String, expected: String)] = [
            (#"{"method_id": 768}"#, "needs priority"),
            (#"{"method_id": 768, "priority": "urgent"}"#, "must be one of input"),
            (#"{"method_id": 768, "priority": "input", "payload": "binary"}"#, "layout version"),
            (#"{"method_id": 768, "priority": "input", "layout_version": 1}"#, "needs payload"),
            (#"{"method_id": 768, "priority": "input", "max_bytes": 33554433}"#, "max_bytes"),
            (#"{"method_id": 768, "priority": "input", "crosses_stream_ok": " "}"#, "non-empty reason"),
            (#"{"method_id": 768, "priority": "input", "durability": "memory", "stream_scoped": "yes"}"#, "boolean"),
            (#"{"method_id": 768, "priority": "input", "durability": "memory", "urgent": 1}"#, "boolean"),
            (#"{"method_id": 65536, "priority": "input"}"#, "must be a u16"),
            (#"{"method_id": 768, "priority": "input", "durability": "memory", "coalesce": {"key": [1]}}"#, "field names"),
            // Durability has no default: a framed command states it.
            (#"{"method_id": 768, "priority": "control"}"#, "needs durability"),
            (#"{"method_id": 768, "priority": "control", "durability": "journal"}"#, "must be one of read_only"),
            (#"{"method_id": 768, "priority": "control", "durability": "memory", "clients": []}"#, "$.commands.a.clients"),
            (#"{"method_id": 768, "priority": "control", "durability": "memory", "clients": "macos"}"#, "client names"),
        ]
        for (command, expected) in cases {
            let message = try Self.refused(sdk: Self.sdk(families: #"{"tabs": {"id": 3}}"#, commands: #"{"a": \#(command)}"#))
            #expect(message.contains(expected), "\(command): \(message)")
        }
    }
}
