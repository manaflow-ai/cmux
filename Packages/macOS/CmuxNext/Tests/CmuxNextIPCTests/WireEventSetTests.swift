import Foundation
import Testing
@testable import CmuxNextIPC
import CmuxNextIPCTestSupport

// `DaemonWireEvent` and its payload types come from CmuxNextIPCTestSupport: CmuxNextWireGen's
// EventEmitter output for the fixture schema, built there at build time.

/// Counts every decode, the way the connection's WireDecoder counts into the wire stats.
private nonisolated final class CountingDecoder: WireEventDecoding {
    private let decoder = JSONDecoder()
    private(set) var count = 0

    func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        count += 1
        return try decoder.decode(type, from: data)
    }
}

/// An event line costs one JSON decode: the name comes from a byte scan, the id from the method
/// table, and only the event's own type is decoded. A TYPED_EVENT payload is
/// decoded by its id with no scan. Every case runs on the emitter's generated `DaemonWireEvent`.
@Suite struct WireEventSetTests {
    // The fixture schema's events, plus `tab-moved` (0xC201): the injected table knows it, the
    // generated set has no case for it, so it stays unknown.
    private static let table: MethodTable = {
        let terminalEvents = MethodTableFamily(id: 0xC0, name: "terminal-events", entries: [
            EventAttributes(id: EventID(rawValue: 0xC000), name: "output", priority: .bulk, coalesce: nil),
            EventAttributes(id: EventID(rawValue: 0xC001), name: "size-state", priority: .control, coalesce: nil),
        ])
        let tabEvents = MethodTableFamily(id: 0xC2, name: "tab-events", entries: [
            EventAttributes(id: EventID(rawValue: 0xC200), name: "tab-created", priority: .control, coalesce: nil),
            EventAttributes(id: EventID(rawValue: 0xC201), name: "tab-moved", priority: .control, coalesce: nil),
            EventAttributes(id: EventID(rawValue: 0xC202), name: "tab-renamed", priority: .background, coalesce: nil),
        ])
        return MethodTable(
            v12: [],
            v2: [],
            events: MethodTable.eventFamilyRange.map { id in [terminalEvents, tabEvents].first { $0.id == id } }
        )
    }()

    /// 20 lines: the `event` key first, last and in the middle; nested objects, arrays and strings
    /// holding `"event"`, escapes, whitespace, and names the table or the set does not know.
    private static let lines: [(line: String, expected: DaemonWireEvent)] = [
        (#"{"event":"output","surface":"s1","seq":1}"#, .output(OutputEvent(surface: "s1", seq: 1))),
        (#"{"surface":"s1","seq":2,"event":"output"}"#, .output(OutputEvent(surface: "s1", seq: 2))),
        (#"{"tab":"t0","event":"tab-created"}"#, .tabCreated(TabCreatedEvent(tab: "t0"))),
        (#" { "event" : "output" , "surface" : "s3" , "seq" : 4 } "#, .output(OutputEvent(surface: "s3", seq: 4))),
        ("{\n\t\"event\":\"output\",\r\n\"surface\":\"s4\",\"seq\":5}", .output(OutputEvent(surface: "s4", seq: 5))),
        (#"{"meta":{"event":"tab-renamed"},"event":"output","surface":"s5","seq":6}"#,
         .output(OutputEvent(surface: "s5", seq: 6))),
        (#"{"tags":["event","{\"event\":1}"],"event":"output","surface":"s6","seq":7}"#,
         .output(OutputEvent(surface: "s6", seq: 7))),
        (#"{"note":"has \"event\":\"x\" inside","event":"output","surface":"s7","seq":8}"#,
         .output(OutputEvent(surface: "s7", seq: 8))),
        (#"{"surface":"s\\8","seq":9,"event":"output"}"#, .output(OutputEvent(surface: "s\\8", seq: 9))),
        (#"{"event":"size-state","surface":"s1","cols":80,"rows":24}"#,
         .sizeState(SizeStateEvent(surface: "s1", cols: 80, rows: 24))),
        (#"{"cols":120,"rows":40,"surface":"s2","event":"size-state"}"#,
         .sizeState(SizeStateEvent(surface: "s2", cols: 120, rows: 40))),
        (#"{"grid":[[1,2],[3,[4,{"event":"output"}]]],"event":"size-state","surface":"s3","cols":1,"rows":1}"#,
         .sizeState(SizeStateEvent(surface: "s3", cols: 1, rows: 1))),
        (#"{"active":true,"gone":null,"ratio":-1.5e3,"event":"size-state","surface":"s4","cols":2,"rows":3}"#,
         .sizeState(SizeStateEvent(surface: "s4", cols: 2, rows: 3))),
        (#"{"event":"tab-renamed","tab":"t1","title":"build"}"#,
         .tabRenamed(TabRenamedEvent(tab: "t1", title: "build"))),
        (#"{"tab":"t2","title":"café \"quoted\"","event":"tab-renamed"}"#,
         .tabRenamed(TabRenamedEvent(tab: "t2", title: "café \"quoted\""))),
        (#"{"event":"tab-renamed","tab":"t3","title":"日本語"}"#,
         .tabRenamed(TabRenamedEvent(tab: "t3", title: "日本語"))),
        (#"{"event":"tab-renamed","title":"","tab":"t4","extra":{"deep":[{}]}}"#,
         .tabRenamed(TabRenamedEvent(tab: "t4", title: ""))),
        // In the table, no case in the set.
        (#"{"event":"tab-moved","tab":"t5"}"#,
         .unknown(name: "tab-moved", raw: Data(#"{"event":"tab-moved","tab":"t5"}"#.utf8))),
        // Not in the table: a newer daemon's event.
        (#"{"event":"surface-glow","surface":"s9"}"#,
         .unknown(name: "surface-glow", raw: Data(#"{"event":"surface-glow","surface":"s9"}"#.utf8))),
        (#"{"seq":1,"event":"later-event"}"#,
         .unknown(name: "later-event", raw: Data(#"{"seq":1,"event":"later-event"}"#.utf8))),
    ]

    @Test func eachLineDecodesOnce() throws {
        #expect(Self.lines.count == 20)
        for (line, expected) in Self.lines {
            let decoder = CountingDecoder()
            let event = try DaemonWireEvent.decode(line: Data(line.utf8), table: Self.table, using: decoder)
            #expect(event == expected, "\(line)")
            let decodes = if case .unknown = expected { 0 } else { 1 }
            #expect(decoder.count == decodes, "\(line): \(decoder.count) decodes")
        }
    }

    /// A TYPED_EVENT payload is the event's object, `event` included, as on a line.
    @Test func typedEventPayloadsDecodeByIDWithoutAScan() throws {
        let decoder = CountingDecoder()
        let payload = Data(#"{"event":"size-state","surface":"s1","cols":80,"rows":24}"#.utf8)
        let event = try DaemonWireEvent.decode(eventID: EventID(rawValue: 0xC001), payload: payload,
                                               table: Self.table, using: decoder)
        #expect(event == .sizeState(SizeStateEvent(surface: "s1", cols: 80, rows: 24)))
        #expect(decoder.count == 1)

        // An id this build does not know keeps the name its payload carries, undecoded.
        let newer = Data(#"{"event":"surface-glow","surface":"s9"}"#.utf8)
        let unknown = try DaemonWireEvent.decode(eventID: EventID(rawValue: 0xC7FF), payload: newer,
                                                 table: Self.table, using: decoder)
        #expect(unknown == .unknown(name: "surface-glow", raw: newer))
        #expect(decoder.count == 1)
    }

    /// An unknown id is never an error: with no readable `event`, its name is the id, and nothing
    /// is parsed.
    @Test func unknownIDWithoutAnEventNameIsNamedByItsID() throws {
        let decoder = CountingDecoder()
        for payload in [#"{"surface":"s9"}"#, #"{"event":"glow\u002Dx"}"#, "[1,2]", ""] {
            let bytes = Data(payload.utf8)
            let event = try DaemonWireEvent.decode(eventID: EventID(rawValue: 0xC7FF), payload: bytes,
                                                   table: Self.table, using: decoder)
            #expect(event == .unknown(name: "0xC7FF", raw: bytes), "\(payload)")
        }
        #expect(decoder.count == 0)
    }

    @Test func scanReadsOnlyTheTopLevelEventKey() {
        #expect(WireEventNameScanner.name(in: Data(#"{"a":{"event":"inner"},"event":"outer"}"#.utf8)) == "outer")
        #expect(WireEventNameScanner.name(in: Data(#"{"a":"\"event\":\"inner\"","event":"outer"}"#.utf8)) == "outer")
        #expect(WireEventNameScanner.name(in: Data(#"{"a":{"event":"inner"}}"#.utf8)) == nil)
        #expect(WireEventNameScanner.name(in: Data(#"["event","outer"]"#.utf8)) == nil)
        #expect(WireEventNameScanner.name(in: Data(#"{"event":null}"#.utf8)) == nil)
        #expect(WireEventNameScanner.name(in: Data(#"{"event":"out"#.utf8)) == nil)
        #expect(WireEventNameScanner.name(in: Data()) == nil)
    }

    /// A name or key the scan cannot read (it holds a JSON escape) falls back to a parse of
    /// `event`, then one decode of the event: two decodes.
    @Test func escapedNameFallsBackToAFullParse() throws {
        let escaped = [
            #"{"event":"size\u002Dstate","surface":"s1","cols":80,"rows":24}"#,
            #"{"surface":"s1","\u0065vent":"size-state","cols":80,"rows":24}"#,
        ]
        for text in escaped {
            let line = Data(text.utf8)
            #expect(line.contains(UInt8(ascii: "\\")), "\(text)")
            #expect(WireEventNameScanner.name(in: line) == nil, "\(text)")
            let decoder = CountingDecoder()
            let event = try DaemonWireEvent.decode(line: line, table: Self.table, using: decoder)
            #expect(event == .sizeState(SizeStateEvent(surface: "s1", cols: 80, rows: 24)), "\(text)")
            #expect(decoder.count == 2, "\(text): \(decoder.count) decodes")
        }
    }

    @Test func refusesLinesWithoutANameOrWithABadPayload() {
        #expect(throws: WireEventDecodeError.self) {
            try DaemonWireEvent.decode(line: Data(#"{"surface":"s1"}"#.utf8), table: Self.table, using: CountingDecoder())
        }
        do throws(WireEventDecodeError) {
            _ = try DaemonWireEvent.decode(line: Data(#"{"event":"output","surface":7}"#.utf8), table: Self.table,
                                           using: CountingDecoder())
            Issue.record("a bad payload decoded")
        } catch {
            #expect(error.isPayload(of: "output"), "\(error)")
        }
    }
}

private extension WireEventDecodeError {
    func isPayload(of event: String) -> Bool {
        if case .payload(let name, _) = self { name == event } else { false }
    }
}
