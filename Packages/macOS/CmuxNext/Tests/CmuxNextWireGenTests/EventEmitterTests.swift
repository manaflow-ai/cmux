import Foundation
import Testing
@testable import CmuxNextWireGen

private func fixtureData(_ file: String) throws -> Data {
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<6 { root.deleteLastPathComponent() }
    return try Data(contentsOf: root.appendingPathComponent("cmux-tui/spec/\(file)"))
}

private func json(_ text: String) throws -> SchemaJSON {
    try JSONDecoder().decode(SchemaJSON.self, from: Data(text.utf8))
}

/// `DaemonWireEvent`'s generator (p05-ipc-022): a case per framed event in id order, `unknown`
/// for the rest, and a decode that switches on the event id and decodes the payload once.
/// The single-decode count itself is WireEventSetTests (CmuxNextIPCTests), over 20 fixture lines.
@Suite struct EventEmitterTests {
    private static func fixture() throws -> EventEmitter {
        try EventEmitter(sdkSchema: fixtureData("fixtures/ipc-method-tables/sdk-schema.json"),
                         resourceOperations: fixtureData("fixtures/ipc-method-tables/resource-operations-v2.json"))
    }

    private static func emitter(events: String) throws -> EventEmitter {
        let sdk = try json(#"{"families": {"terminal-events": {"id": 192}}, "commands": {}, "events": \#(events)}"#)
        return try EventEmitter(schema: MethodTableSchema(sdk: sdk, v2: json(#"{"operations": {}}"#)))
    }

    @Test func casesFollowTheFramedEventsInIDOrder() throws {
        let cases = try Self.fixture().cases
        #expect(cases == [
            EventEmitter.Case(id: 0xC000, name: "output", caseName: "output", payloadType: "OutputEvent"),
            EventEmitter.Case(id: 0xC001, name: "size-state", caseName: "sizeState", payloadType: "SizeStateEvent"),
            EventEmitter.Case(id: 0xC200, name: "tab-created", caseName: "tabCreated", payloadType: "TabCreatedEvent"),
            EventEmitter.Case(id: 0xC202, name: "tab-renamed", caseName: "tabRenamed", payloadType: "TabRenamedEvent"),
        ])
        // `unframed-event` has no event_id: it decodes as `unknown`, with no case.
        #expect(!cases.contains { $0.name == "unframed-event" })
    }

    @Test func emitsOneDecodePerCase() throws {
        let source = try Self.fixture().source()
        #expect(source.contains("public enum DaemonWireEvent: Sendable, Equatable {"))
        #expect(source.contains("    case sizeState(SizeStateEvent)\n"))
        #expect(source.contains("    case unknown(name: String, raw: Data)\n"))
        #expect(source.contains("        case .sizeState: \"size-state\"\n"))
        #expect(source.contains(
            "        case 0xC001: return .sizeState(try decoder.decode(SizeStateEvent.self, from: payload))\n"))
        #expect(source.contains("extension DaemonWireEvent: WireEventSet {"))
        #expect(source.contains("try decode(line: line, table: .schema, using: decoder)"))
        #expect(source.contains("try decode(eventID: eventID, payload: payload, table: .schema, using: decoder)"))
        // Each case decodes exactly once in the switch, and nothing else decodes.
        #expect(source.components(separatedBy: "decoder.decode(").count - 1 == 4)
        #expect(!source.contains("JSONDecoder"))
        #expect(!source.contains("keyDecodingStrategy"))
    }

    @Test func emitsTheSameBytesEveryRun() throws {
        #expect(try Self.fixture().source() == Self.fixture().source())
    }

    /// Every framed event of the real schema gets a case and a distinct Swift name.
    @Test func coversEveryFramedEventOfTheSchema() throws {
        let emitter = try EventEmitter(sdkSchema: fixtureData("sdk-schema.json"),
                                       resourceOperations: fixtureData("resource-operations-v2.json"))
        let sdk = try json(String(decoding: fixtureData("sdk-schema.json"), as: UTF8.self))
        let framed = (sdk["events"]?.object ?? [:]).filter { $0.value["event_id"] != nil }.keys.sorted()
        #expect(emitter.cases.map(\.name).sorted() == framed)
        #expect(Set(emitter.cases.map(\.caseName)).count == emitter.cases.count)
        #expect(emitter.cases.map(\.id) == emitter.cases.map(\.id).sorted())
    }

    @Test func namesBecomeSwiftCases() throws {
        let emitter = try Self.emitter(events: #"""
            {"default": {"event_id": 49152, "priority": "control"},
             "cloud.mux_wake-2": {"event_id": 49153, "priority": "control"}}
            """#)
        #expect(emitter.cases.map(\.caseName) == ["`default`", "cloudMuxWake2"])
        #expect(emitter.cases.map(\.payloadType) == ["DefaultEvent", "CloudMuxWake2Event"])
        #expect(emitter.source().contains("case .`default`: \"default\""))
    }

    @Test func refusesNamesWithoutADistinctCase() throws {
        let refusals: [(events: String, expected: String)] = [
            (#"{"a-b": {"event_id": 49152, "priority": "control"}, "a_b": {"event_id": 49153, "priority": "control"}}"#,
             "is also a-b"),
            (#"{"unknown": {"event_id": 49152, "priority": "control"}}"#, "is also the unknown case"),
            (#"{"2fa": {"event_id": 49152, "priority": "control"}}"#, "has no Swift case"),
            (#"{"tab added": {"event_id": 49152, "priority": "control"}}"#, "has no Swift case"),
        ]
        for (events, expected) in refusals {
            do {
                _ = try Self.emitter(events: events)
                Issue.record("not refused: \(events)")
            } catch {
                #expect("\(error)".contains(expected), "\(events): \(error)")
                #expect("\(error)".hasPrefix("sdk-schema.json: $.events."), "\(error)")
            }
        }
    }
}
