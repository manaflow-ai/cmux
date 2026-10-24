import AppKit
@testable import CmuxNextApp
import CmuxNextBridge
@testable import CmuxNextDaemon
import CmuxNextDesign
import Foundation
import Testing

/// A status change costs the finished-run follower the workspace whose status changed, not the
/// session: a script that sets statuses in 50 workspaces (`cmux status set`, `cmux status run`)
/// must not make it scan every workspace's status on each change (CLAUDE.md "Go past Chrome where
/// cmux is scripted").
@MainActor @Suite(.timeLimit(.minutes(1))) struct StatusRunFollowCostTests {
    private static func store(_ count: Int) throws -> DaemonStore {
        _ = NSApplication.shared
        let store = DaemonStore()
        store.connectionState = .connected(try JSONDecoder().decode(DaemonIdentity.self, from: Data(
            #"{"app":"cmux-tui","protocol":1,"session":"status-follow-cost","generation":"g1"}"#.utf8)))
        store.apply(snapshot: DaemonTree(workspaces: (1...count).map { index in
            let id = UInt64(index)
            let pane = PaneSnapshot(id: PaneID(rawValue: id), tabs: [TabSnapshot(surface: SurfaceID(rawValue: id), terminalResourceID: ResourceID(rawValue: "term_\(index)"))])
            let screen = ScreenSnapshot(id: ScreenID(rawValue: id), layout: .leaf(PaneID(rawValue: id)), panes: [pane])
            return WorkspaceSnapshot(id: WorkspaceHandle(rawValue: id), key: WorkspaceKey(rawValue: "w\(index)"),
                                     resourceID: ResourceID(rawValue: "ws_\(index)"), name: "w\(index)", screens: [screen])
        }))
        let workspaces = (1...count).map { #"{"id":"ws_\#($0)"}"# }.joined(separator: ",")
        let statuses = (1...count).map { #"{"workspace_id":"ws_\#($0)","entries":[]}"# }.joined(separator: ",")
        let line = #"{"type":"stream_item","item":{"kind":"snapshot","snapshot":{"workspaces":["# + workspaces + #"],"terminals":[],"#
            + #""extra":{"state":{"workspace_status":["# + statuses + "]}}}}}"
        store.session.apply(try #require(SessionStreamItem.decode(Data(line.utf8))), in: store)
        return store
    }

    private static func setStatus(_ index: Int, text: String, in store: DaemonStore) throws {
        let entry = #"{"key":"build","text":"\#(text)","state":"busy","updated_at_ms":"1"}"#
        try apply(index, entries: entry, in: store)
    }

    /// Writes workspace `index`'s `run:9` entry as `cmux status run` does: busy, or finished after a minute.
    private static func run(_ index: Int, finished: Bool, in store: DaemonStore) throws {
        let state = finished ? #""state":"success","exit_code":0,"duration_ms":"60000","updated_at_ms":"2""# : #""state":"busy","updated_at_ms":"1""#
        try apply(index, entries: #"{"key":"run:9","text":"Fence","target_terminal":"term_\#(index)",\#(state)}"#, in: store)
    }

    private static func apply(_ index: Int, entries: String, in store: DaemonStore) throws {
        let line = #"{"type":"stream_item","item":{"kind":"delta","changes":[{"kind":"state_upsert","resource":"workspace_status","id":"ws_\#(index)","value":{"workspace_id":"ws_\#(index)","entries":["#
            + entries + "]}}]}}"
        store.session.apply(try #require(SessionStreamItem.decode(Data(line.utf8))), in: store)
    }

    @Test(arguments: [50, 500])
    func oneStatusChangeExaminesOneWorkspace(sessionSize: Int) async throws {
        let store = try Self.store(sessionSize)
        let service = NotificationCenterService()
        // Every status the follower examines asks for the notification settings once: the count
        // and the wake-up come from that injected seam, not from a counter the follower keeps.
        let examinations = StatusExaminationCount()
        let (examined, examining) = AsyncStream<Void>.makeStream()
        let (posted, posting) = AsyncStream<SurfaceID?>.makeStream()
        var wakes = examined.makeAsyncIterator()
        var notices = posted.makeAsyncIterator()
        let behavior = StatusBehaviorSettings()
        let task = service.followStatusRuns(store, behavior: {
            examinations.count += 1
            examining.yield()
            return behavior
        }, visibility: { _ in .hidden }, post: { posting.yield($0.surface) })
        defer { task.cancel() }
        // The first pass examines every workspace's status once (it learns the runs busy now).
        for _ in 0..<sessionSize { _ = await wakes.next() }
        #expect(examinations.count == sessionSize)
        // The fence's run, in the last workspace, is seen busy before the measured change.
        try Self.run(sessionSize, finished: false, in: store)
        _ = await wakes.next()
        let before = examinations.count
        try Self.setStatus(7, text: "building", in: store)
        // The fence: the last workspace's run finishes after the measured change. Its notice is
        // posted after every change queued before it was examined (one queue, in order), so a
        // change that woke more watches than its own is counted by then, however many turns the
        // follower took for it.
        try Self.run(sessionSize, finished: true, in: store)
        let fence = await notices.next() ?? nil
        #expect(fence == SurfaceID(rawValue: UInt64(sessionSize)), "the fence's notice: \(String(describing: fence))")
        let examinedForOne = examinations.count - before - 1
        #expect(examinedForOne == 1, "one status change examined \(examinedForOne) workspaces in a \(sessionSize)-workspace session")
    }
}
