import Foundation
import Testing
@testable import CmuxNextDaemon

/// ``DaemonEvent/decode(name:line:)`` parses an event line once. The connection's
/// counting decoder sees one decode per event: the name picks the payload type, and that parse
/// also gives the `unknown` payload of a line whose fields do not match. Before, `layout-changed`
/// with a layout, a pairing event and every mismatched line cost two.
struct DaemonEventSingleDecodeTests {
    /// One subscribe-stream line and the event it decodes to.
    struct Fixture: Sendable, CustomTestStringConvertible {
        let name: String
        let line: String
        let expected: @Sendable (DaemonEvent) -> Bool
        var testDescription: String { line }
    }

    static let inventoryMachine = "machine_0123456789abcdef0123456789abcdef"
    static let inventoryWatch = "inventory_watch_0123456789abcdef0123456789abcdef"

    /// Twenty event lines the daemon sends, each a different event, over every way the decode
    /// builds an event: a case from one payload struct, a flat layout beside its screen, `unknown`
    /// side events with exact u64 decimals, client events, the cloud set and a `session.events`
    /// stream line.
    static let fixtures: [Fixture] = [
        Fixture(name: "title-changed", line: #"{"event":"title-changed","surface":4,"title":"~/src"}"#) {
            $0 == .titleChanged(surface: SurfaceID(rawValue: 4), title: "~/src")
        },
        Fixture(name: "surface-resized", line: #"{"event":"surface-resized","surface":4,"cols":80,"rows":24}"#) {
            $0 == .surfaceResized(surface: SurfaceID(rawValue: 4), size: CellSize(cols: 80, rows: 24))
        },
        Fixture(name: "surface-exited", line: #"{"event":"surface-exited","surface":4}"#) {
            $0 == .surfaceExited(surface: SurfaceID(rawValue: 4))
        },
        Fixture(name: "scroll-changed", line: #"{"event":"scroll-changed","surface":4,"offset":10,"at_bottom":true}"#) {
            $0 == .scrollChanged(surface: SurfaceID(rawValue: 4), offset: 10, atBottom: true)
        },
        Fixture(name: "bell", line: #"{"event":"bell","surface":4}"#) {
            $0 == .bell(surface: SurfaceID(rawValue: 4))
        },
        Fixture(name: "tree-changed", line: #"{"event":"tree-changed","transaction":"tx1"}"#) {
            $0 == .treeChanged(transaction: ClientTransactionID(rawValue: "tx1"))
        },
        Fixture(
            name: "layout-changed",
            line: #"{"event":"layout-changed","screen":2,"transaction":"tx2","active_pane":3,"layout":{"type":"leaf","pane":3}}"#
        ) {
            $0 == .layoutChanged(
                screen: ScreenID(rawValue: 2),
                layout: ScreenLayoutDelta(activePane: PaneID(rawValue: 3), layout: .leaf(PaneID(rawValue: 3))),
                transaction: ClientTransactionID(rawValue: "tx2"))
        },
        Fixture(name: "keybindings-changed", line: #"{"event":"keybindings-changed","revision":3}"#) {
            $0 == .keybindingsChanged(revision: 3)
        },
        Fixture(name: "history-changed", line: #"{"event":"history-changed","revision":4,"kinds":["visit"]}"#) {
            $0 == .historyChanged(revision: 4, kinds: ["visit"])
        },
        Fixture(
            name: "bookmarks-changed",
            line: #"{"event":"bookmarks-changed","browser_profile_id":"default","bookmarks_revision":2}"#
        ) {
            $0 == .bookmarksChanged(browserProfileID: "default", revision: 2)
        },
        Fixture(name: "terminal-registry-changed", line: #"{"event":"terminal-registry-changed","terminal_revision":9}"#) {
            $0 == .terminalRegistryChanged(revision: 9)
        },
        Fixture(name: "overflow", line: #"{"event":"overflow","error":"lagged"}"#) {
            $0 == .overflow("lagged")
        },
        Fixture(
            name: "terminal-clipboard-read-cancelled",
            line: #"{"event":"terminal-clipboard-read-cancelled","request_id":"r1"}"#
        ) {
            $0 == .terminalClipboardReadCancelled(requestID: "r1")
        },
        Fixture(name: "pairing-requested", line: #"{"event":"pairing-requested","request":7,"origin":"o"}"#) {
            $0 == .unknown(name: "pairing-requested", payload: .object([
                "event": .string("pairing-requested"), "request": .number(7), "origin": .string("o"),
                "request_id": .string("7"),
            ]))
        },
        Fixture(name: "client-attached", line: #"{"event":"client-attached","client":"c1"}"#) {
            $0 == .client(name: "client-attached", payload: .object([
                "event": .string("client-attached"), "client": .string("c1"),
            ]))
        },
        Fixture(name: "agent-changed", line: #"{"event":"agent-changed","surface":1,"state":"working","updated_at_ms":5}"#) {
            guard case .agentChanged(let status) = $0 else { return false }
            return status.surface == SurfaceID(rawValue: 1) && status.updatedAtMs == 5
        },
        Fixture(
            name: "apps-agent-inventory-demand",
            line: #"{"event":"apps-agent-inventory-demand","sequence":9007199254740993,"enabled":true}"#
        ) {
            $0 == .unknown(name: "apps-agent-inventory-demand", payload: .object([
                "sequence": .string("9007199254740993"), "enabled": .bool(true),
            ]))
        },
        Fixture(
            name: "agent-inventory-changed",
            line: #"{"event":"agent-inventory-changed","machine":"\#(DaemonEventSingleDecodeTests.inventoryMachine)","#
                + #""watch_id":"\#(DaemonEventSingleDecodeTests.inventoryWatch)","revision":12}"#
        ) {
            guard case .unknown("agent-inventory-changed", let payload) = $0 else { return false }
            return payload["revision"] == .string("12") && payload["watch_id"] == .string(DaemonEventSingleDecodeTests.inventoryWatch)
        },
        Fixture(name: "cloud-inbox-reset", line: #"{"event":"cloud-inbox-reset","seq":3,"account":"a"}"#) {
            $0 == .cloudConversations(.inboxReset(seq: 3, account: "a"))
        },
        Fixture(name: LineTransport.streamEvent, line: #"{"type":"stream_end","stream_id":"7","reason":"gap"}"#) {
            $0 == .sessionState(.ended(reason: "gap"))
        },
    ]

    /// The decodes `name`'s line costs on a counting decoder, and the event it gives.
    private static func decodeCounted(name: String, line: String) -> (decodes: UInt64, event: DaemonEvent) {
        let stats = DaemonWireStats()
        let event = DaemonEvent.decode(name: name, line: Data(line.utf8), decoder: WireCoding.decoder(stats.recorder()))
        return (stats.snapshot().jsonDecodes, event)
    }

    @Test func theFixtureHasTwentyEventLines() {
        #expect(Self.fixtures.count == 20)
        #expect(Set(Self.fixtures.map(\.name)).count == 20, "each fixture line is a different event")
    }

    @Test(arguments: DaemonEventSingleDecodeTests.fixtures)
    func eachEventLineCostsOneDecode(_ fixture: Fixture) {
        let (decodes, event) = Self.decodeCounted(name: fixture.name, line: fixture.line)
        #expect(decodes == 1)
        #expect(fixture.expected(event), "\(fixture.name) decoded as \(event)")
    }

    /// A field of the wrong type: the line is `unknown` with its JSON, from the same one parse.
    @Test func aMismatchedLineIsUnknownFromOneDecode() throws {
        let line = #"{"event":"title-changed","surface":"s","title":"t"}"#
        let (decodes, event) = Self.decodeCounted(name: "title-changed", line: line)
        #expect(decodes == 1)
        let payload = try JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
        #expect(event == .unknown(name: "title-changed", payload: payload))
    }

    /// A layout that does not decode refetches (no layout), still from one parse.
    @Test func anUndecodableLayoutIsNilFromOneDecode() {
        let line = #"{"event":"layout-changed","screen":2,"layout":{"columns":[]},"transaction":"tx1"}"#
        let (decodes, event) = Self.decodeCounted(name: "layout-changed", line: line)
        #expect(decodes == 1)
        #expect(event == .layoutChanged(screen: ScreenID(rawValue: 2), layout: nil, transaction: ClientTransactionID(rawValue: "tx1")))
    }

    /// A `layout-changed` without layout fields refetches (no layout), from one parse.
    @Test func anAbsentLayoutIsNilFromOneDecode() {
        let (decodes, event) = Self.decodeCounted(name: "layout-changed", line: #"{"event":"layout-changed","screen":2}"#)
        #expect(decodes == 1)
        #expect(event == .layoutChanged(screen: ScreenID(rawValue: 2), layout: nil, transaction: nil))
    }

    /// A `cloud-*` line whose fields do not match is `unknown` with its JSON, from the same one
    /// parse, like every other event.
    @Test func aMismatchedCloudLineIsUnknownFromOneDecode() throws {
        let line = #"{"event":"cloud-inbox-reset","seq":"three"}"#
        let (decodes, event) = Self.decodeCounted(name: "cloud-inbox-reset", line: line)
        #expect(decodes == 1)
        let payload = try JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
        #expect(event == .unknown(name: "cloud-inbox-reset", payload: payload))
    }

    /// A pairing id past 2^53 survives exactly as `request_id`, from one parse.
    @Test func aPairingRequestKeepsItsExactIDFromOneDecode() {
        let line = #"{"event":"pairing-resolved","request":18446744073709551615}"#
        let (decodes, event) = Self.decodeCounted(name: "pairing-resolved", line: line)
        #expect(decodes == 1)
        guard case .unknown("pairing-resolved", let payload) = event else {
            Issue.record("pairing-resolved decoded as \(event)")
            return
        }
        #expect(payload["request_id"] == .string("18446744073709551615"))
    }

    /// Events whose payload is never read cost no decode.
    @Test(arguments: ["personal-changed", "daemon-shutdown"])
    func payloadFreeEventsCostNoDecode(name: String) {
        let (decodes, event) = Self.decodeCounted(name: name, line: #"{"event":"\#(name)"}"#)
        let expected: DaemonEvent = name == "personal-changed" ? .personalChanged : .daemonShutdown
        #expect(decodes == 0)
        #expect(event == expected)
    }

    /// A name the app does not model is `unknown` with its JSON, from one parse; a line that is not
    /// JSON is `unknown` with `.null`.
    @Test func anUnmodeledNameCostsOneDecode() {
        let modeled = Self.decodeCounted(name: "fuzz-x", line: #"{"event":"fuzz-x","a":1}"#)
        #expect(modeled.decodes == 1)
        #expect(modeled.event == .unknown(name: "fuzz-x", payload: .object(["event": .string("fuzz-x"), "a": .number(1)])))
        let broken = Self.decodeCounted(name: "bell", line: "#not json")
        #expect(broken.decodes == 1)
        #expect(broken.event == .unknown(name: "bell", payload: .null))
    }

    // The decoding table against the schema (p05-ipc.md Q12, "schema events minus DaemonEvent
    // cases"): a new sdk-schema.json event fails here until it gets a table entry or joins
    // `unmodeledSchemaEvents`, and a table name the schema dropped fails too.

    /// Schema events the app does not decode natively: they arrive as `unknown` (or on another
    /// connection: the terminal stream, loopback, cloud mux). Q12's open list.
    static let unmodeledSchemaEvents: Set<String> = [
        "activity-changed", "browser-state", "chief-changed", "cloud-mux-resynced", "cloud-mux-wake", "colors-changed",
        "config-reload-requested", "conversation-inbox-changed", "detached", "empty", "frame", "graphics-status",
        "loopback-closed", "loopback-credit", "loopback-data", "loopback-eof", "machine-usage-changed", "output",
        "participant-avatar-changed", "program-status-changed", "render-delta", "render-state", "resized", "script-log",
        "server-diagnostic-site", "settings-changed", "size-state", "status", "surface-output", "surface-resize-failed", "terminal-input-unclaimed",
        "terminal-reaped", "url-open", "vt-state", "window-title-requested",
    ]

    /// Table names that are not sdk-schema.json events: the apps-extension inventory demand and
    /// the `session.events` stream line.
    static let appSideEventNames: Set<String> = ["apps-agent-inventory-demand", LineTransport.streamEvent]

    @Test func theDecodingTableMatchesTheSchemaEvents() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { root.deleteLastPathComponent() }
        let schema = try JSONDecoder().decode(
            SchemaEventNames.self, from: Data(contentsOf: root.appendingPathComponent("cmux-tui/spec/sdk-schema.json")))
        let modeled = DaemonEvent.modeledEventNames
        #expect(modeled.subtracting(Self.appSideEventNames).subtracting(schema.names).sorted() == [],
                "table names that are not schema events")
        #expect(schema.names.subtracting(modeled).subtracting(Self.unmodeledSchemaEvents).sorted() == [],
                "schema events with no table entry: add one, or list them in unmodeledSchemaEvents")
        #expect(Self.unmodeledSchemaEvents.intersection(modeled).sorted() == [], "modeled events still listed as unmodeled")
        #expect(Self.unmodeledSchemaEvents.subtracting(schema.names).sorted() == [], "unmodeled names the schema dropped")
    }
}

/// The event names of sdk-schema.json: the keys of its `events` object.
private struct SchemaEventNames: Decodable {
    let names: Set<String>

    private enum CodingKeys: String, CodingKey { case events }

    private struct EventName: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    init(from decoder: any Decoder) throws {
        let events = try decoder.container(keyedBy: CodingKeys.self).nestedContainer(keyedBy: EventName.self, forKey: .events)
        names = Set(events.allKeys.map(\.stringValue))
    }
}
