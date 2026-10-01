import Foundation
import Synchronization
import Testing
@testable import CmuxNextDaemon

/// Workspace status reaches the app through the connection's
/// `session.events` stream (resource API v2): decoding its lines, keeping
/// only the current stream, and the store's status map.
@MainActor @Suite(.timeLimit(.minutes(1))) struct WorkspaceStatusStreamTests {
    static let stream = "stream_0123456789abcdef0123456789abcdef"

    static let statusJSON = #"""
    {"workspace_id":"ws_a","entries":[{"key":"build","text":"Running","icon":"hammer","color":"#ff8800","updated_at_ms":"1"}],
     "progress":{"value":0.5,"label":"Tests","updated_at_ms":"2"},"log_count":2,
     "last_log":{"sequence":"2","level":"success","source":null,"text":"done","at_ms":"3"}}
    """#.replacingOccurrences(of: "\n", with: "")

    static func snapshotLine(stream: String = stream) -> String {
        #"{"protocol":"cmux.protocol/2","type":"stream_item","stream_id":"\#(stream)","sequence":"0","cursor":{"generation":"g","revision":"4"},"item":{"kind":"snapshot","cursor":{"generation":"g","revision":"4"},"reset_reason":"initial","snapshot":{"workspaces":[{"id":"ws_a"}],"terminals":[],"extra":{"state":{"tab_groups":[],"workspace_status":[\#(statusJSON)]}}}}}"#
    }

    static func deltaLine(_ changes: String, stream: String = stream) -> String {
        #"{"protocol":"cmux.protocol/2","type":"stream_item","stream_id":"\#(stream)","sequence":"1","cursor":{"generation":"g","revision":"5"},"item":{"kind":"delta","cursor":{"generation":"g","revision":"5"},"previous_revision":"4","revision":"5","changes":[\#(changes)]}}"#
    }

    static func endLine(stream: String = stream) -> String {
        #"{"protocol":"cmux.protocol/2","type":"stream_end","stream_id":"\#(stream)","reason":"gap","recovery":"request a fresh session snapshot"}"#
    }

    static func decode(_ line: String) -> DaemonEvent {
        let data = Data(line.utf8)
        let type = (try? JSONDecoder().decode([String: JSONValue].self, from: data))?["type"]?.stringValue ?? ""
        return DaemonEvent.decode(name: type, line: data)
    }

    // MARK: Decoding

    @Test func snapshotItemCarriesEveryWorkspaceStatus() throws {
        guard case .workspaceStatus(.reset(let list), let stream) = Self.decode(Self.snapshotLine()) else {
            Issue.record("snapshot did not decode as a status reset")
            return
        }
        #expect(stream == Self.stream)
        let status = try #require(list.first)
        #expect(status.workspaceID == "ws_a")
        #expect(status.entries == [.init(key: "build", text: "Running", icon: "hammer", color: "#ff8800")])
        #expect(status.progress == .init(value: 0.5, label: "Tests"))
        #expect(status.logCount == 2)
        #expect(status.lastLog == .init(level: "success", text: "done"))
    }

    @Test func deltaKeepsOnlyStatusChangesInOrder() {
        let changes = [
            #"{"kind":"upsert","sequence":0,"resource":"terminal","id":"term_1","value":{"id":"term_1"}}"#,
            #"{"kind":"state_upsert","sequence":1,"resource":"workspace_status","id":"ws_a","value":\#(Self.statusJSON)}"#,
            #"{"kind":"state_upsert","sequence":2,"resource":"closed","id":"c1","value":{"id":"c1"}}"#,
            #"{"kind":"state_delete","sequence":3,"resource":"workspace_status","id":"ws_b"}"#,
        ].joined(separator: ",")
        guard case .workspaceStatus(.changes(let items), _) = Self.decode(Self.deltaLine(changes)) else {
            Issue.record("delta did not decode as status changes")
            return
        }
        #expect(items.count == 2)
        if case .upsert(let snapshot) = items[0] { #expect(snapshot.workspaceID == "ws_a") } else { Issue.record("first is not an upsert") }
        #expect(items[1] == .delete("ws_b"))
    }

    @Test func deltaWithoutStatusIsAnUnknownStreamLine() {
        let line = Self.deltaLine(#"{"kind":"upsert","sequence":0,"resource":"tab","id":"tab_1","value":{"id":"tab_1"}}"#)
        guard case .unknown(let name, _) = Self.decode(line) else {
            Issue.record("status-less delta became a status event")
            return
        }
        #expect(name == "stream_item")
    }

    @Test func streamEndNamesItsStream() {
        #expect(Self.decode(Self.endLine()) == .sessionEventsEnded(stream: Self.stream))
    }

    // MARK: Tracker

    @Test func trackerAdmitsOnlyTheCurrentStreamAndDropsStatuslessLines() {
        let tracker = SessionEventsTracker()
        let (current, replaced) = tracker.begin(resetBudget: true)
        #expect(replaced == nil)
        #expect(current.hasPrefix("stream_") && current.count == 39)
        var reopens = 0
        #expect(tracker.admit(.workspaceStatus(.reset([]), stream: current)) { reopens += 1 })
        #expect(!tracker.admit(.workspaceStatus(.reset([]), stream: Self.stream)) { reopens += 1 })
        #expect(!tracker.admit(.unknown(name: "stream_item", payload: .null)) { reopens += 1 })
        #expect(tracker.admit(.bell(surface: 1)) { reopens += 1 })
        #expect(reopens == 0)
    }

    @Test func endsReopenWithinTheBudgetAndASnapshotRefillsIt() {
        let tracker = SessionEventsTracker()
        var reopens = 0
        for _ in 0..<(SessionEventsTracker.reopenBudget + 2) {
            let (id, _) = tracker.begin(resetBudget: false)
            #expect(!tracker.admit(.sessionEventsEnded(stream: id)) { reopens += 1 })
        }
        #expect(reopens == SessionEventsTracker.reopenBudget)
        // A stream that delivers its snapshot earns the full budget again.
        let (id, _) = tracker.begin(resetBudget: false)
        #expect(tracker.admit(.workspaceStatus(.reset([]), stream: id)) {})
        #expect(!tracker.admit(.sessionEventsEnded(stream: id)) { reopens += 1 })
        #expect(reopens == SessionEventsTracker.reopenBudget + 1)
        // An end of a replaced stream does nothing.
        #expect(!tracker.admit(.sessionEventsEnded(stream: Self.stream)) { reopens += 1 })
        #expect(reopens == SessionEventsTracker.reopenBudget + 1)
    }

    @Test func aClosedSocketLeavesNoStreamToCancel() {
        let tracker = SessionEventsTracker()
        _ = tracker.begin(resetBudget: true)
        tracker.forget()
        #expect(tracker.begin(resetBudget: true).replaced == nil)
    }

    // MARK: Store

    private func snapshot(_ id: ResourceID, _ text: String) -> WorkspaceStatusSnapshot {
        WorkspaceStatusSnapshot(workspaceID: id, entries: [.init(key: "k", text: text)])
    }

    @Test func storeAppliesResetUpsertAndDelete() {
        let store = DaemonStore()
        store.apply(.workspaceStatus(.reset([snapshot("ws_a", "a"), WorkspaceStatusSnapshot(workspaceID: "ws_empty")]), stream: "s"))
        #expect(Set(store.workspaceStatus.keys) == ["ws_a"])
        store.apply(.workspaceStatus(.changes([.upsert(snapshot("ws_b", "b")), .upsert(snapshot("ws_a", "a2"))]), stream: "s"))
        #expect(store.workspaceStatus["ws_a"]?.entries.first?.text == "a2")
        #expect(store.workspaceStatus["ws_b"] != nil)
        // `workspace status clear` and friends leave an empty snapshot.
        store.apply(.workspaceStatus(.changes([.upsert(WorkspaceStatusSnapshot(workspaceID: "ws_b"))]), stream: "s"))
        #expect(store.workspaceStatus["ws_b"] == nil)
        // The workspace closed.
        store.apply(.workspaceStatus(.changes([.delete("ws_a")]), stream: "s"))
        #expect(store.workspaceStatus.isEmpty)
    }

    @Test func statusIsNeverSupersededByATreeSnapshot() throws {
        let store = DaemonStore()
        store.apply(snapshot: try Fixture.response(DaemonTree.self, "list-workspaces.json"))
        store.snapshotBarrier = 10
        _ = store.apply(batch: [DaemonEventEnvelope(sequence: 3, event: .workspaceStatus(.reset([snapshot("ws_a", "a")]), stream: "s"))])
        #expect(store.workspaceStatus["ws_a"] != nil)
    }

    @Test func statusLooksUpTheWorkspaceByItsResourceID() throws {
        let store = DaemonStore()
        store.apply(snapshot: try Fixture.response(DaemonTree.self, "list-workspaces.json"))
        let workspace = try #require(store.workspaces.first { $0.resourceID != nil })
        let id = try #require(workspace.resourceID)
        store.apply(.workspaceStatus(.reset([snapshot(id, "mine")]), stream: "s"))
        #expect(store.status(of: workspace)?.entries.first?.text == "mine")
    }

    @Test func aNewConnectionClearsStatusUntilItsSnapshot() {
        let store = DaemonStore()
        store.apply(.workspaceStatus(.reset([snapshot("ws_a", "a")]), stream: "s"))
        let identity = DaemonIdentity(generation: "g")
        store.apply(.connected(identity, generationChanged: false))
        #expect(store.workspaceStatus.isEmpty)
    }

    @Test func aCollapsedInboxKeepsOneStaleMarkerForDroppedStatus() {
        let inbox = EventInbox(limit: 4)
        var sequence: UInt64 = 0
        func push(_ event: DaemonEvent) {
            sequence += 1
            _ = inbox.append(DaemonEventEnvelope(sequence: sequence, event: event))
        }
        for index in 0..<10 { push(.titleChanged(surface: 1, title: "\(index)")) }
        for index in 0..<10 { push(.workspaceStatus(.changes([.delete(ResourceID(rawValue: "ws_\(index)"))]), stream: "s")) }
        let stale = inbox.take().filter {
            if case .workspaceStatus(.stale, _) = $0.event { true } else { false }
        }
        #expect(stale.count == 1)
    }

    // MARK: Connection

    @Test func connectionOpensTheStreamAndDeliversItsSnapshotAfterConnected() async throws {
        let opened = Mutex<String?>(nil)
        let identify = ConnectionTests.identify.replacingOccurrences(of: #""attach-initial-size""#,
                                                                     with: #""attach-initial-size","terminal-reap-v1""#)
        let server = try FakeDaemonServer(handler: { request in
            let id = request["id"]?.intValue ?? 0
            switch request["cmd"]?.stringValue {
            case "identify": return [#"{"id":\#(id),"ok":true,"data":\#(identify)}"#]
            case "set-client-info", "subscribe": return [#"{"id":\#(id),"ok":true,"data":{}}"#]
            default: break
            }
            guard request["operation"]?.stringValue == "session.events",
                  case .object(let params)? = request["params"], let stream = params["stream_id"]?.stringValue,
                  let requestID = request["id"]?.stringValue else { return [] }
            opened.withLock { $0 = stream }
            return [
                #"{"protocol":"cmux.protocol/2","type":"response","id":"\#(requestID)","ok":true,"result":{"stream_id":"\#(stream)"}}"#,
                Self.snapshotLine(stream: stream),
                // A delta without status never reaches the app.
                Self.deltaLine(#"{"kind":"upsert","sequence":0,"resource":"tab","id":"tab_1","value":{}}"#, stream: stream),
                Self.deltaLine(#"{"kind":"state_delete","sequence":0,"resource":"workspace_status","id":"ws_a"}"#, stream: stream),
            ]
        })
        defer { server.stop() }
        let connection = DaemonConnection(endpoint: DaemonEndpoint(socketPath: server.path))
        try await connection.start()
        var iterator = connection.events.makeAsyncIterator()
        var events: [DaemonEvent] = []
        while events.count < 3, let next = try await iterator.next() { events.append(next.event) }
        guard case .connected = events[0] else {
            Issue.record("first event is not .connected")
            return
        }
        let stream = try #require(opened.withLock { $0 })
        guard case .workspaceStatus(.reset(let list), let id) = events[1] else {
            Issue.record("second event is not the status snapshot")
            return
        }
        #expect(id == stream)
        #expect(list.map(\.workspaceID) == ["ws_a"])
        #expect(events[2] == .workspaceStatus(.changes([.delete("ws_a")]), stream: stream))
        await connection.close()
    }
}
