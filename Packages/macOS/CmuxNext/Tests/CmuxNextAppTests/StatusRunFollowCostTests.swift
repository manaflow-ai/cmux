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
        let line = #"{"type":"stream_item","item":{"kind":"delta","changes":[{"kind":"state_upsert","resource":"workspace_status","id":"ws_\#(index)","value":{"workspace_id":"ws_\#(index)","entries":["#
            + entry + "]}}]}}"
        store.session.apply(try #require(SessionStreamItem.decode(Data(line.utf8))), in: store)
    }

    @Test(arguments: [50, 500])
    func oneStatusChangeExaminesOneWorkspace(sessionSize: Int) async throws {
        let store = try Self.store(sessionSize)
        let service = NotificationCenterService()
        // Every status the follower examines asks for the notification settings once: the count
        // and the wake-up come from that injected seam, not from a counter the follower keeps.
        let examinations = ExaminationCount()
        let (examined, examining) = AsyncStream<Void>.makeStream()
        var wakes = examined.makeAsyncIterator()
        let behavior = StatusBehaviorSettings()
        let task = service.followStatusRuns(store, behavior: {
            examinations.count += 1
            examining.yield()
            return behavior
        }, visibility: { _ in .hidden }, post: { _ in })
        defer { task.cancel() }
        // The first pass examines every workspace's status once (it learns the runs busy now).
        for _ in 0..<sessionSize { _ = await wakes.next() }
        #expect(examinations.count == sessionSize)
        let before = examinations.count
        try Self.setStatus(7, text: "building", in: store)
        // The follower examines a change in one synchronous pass, so all of it is counted by the
        // time its first examination wakes this test.
        _ = await wakes.next()
        let examinedForOne = examinations.count - before
        #expect(examinedForOne == 1, "one status change examined \(examinedForOne) workspaces in a \(sessionSize)-workspace session")
    }
}

/// How many statuses the follower examined (main actor, written by the test's settings closure).
@MainActor private final class ExaminationCount {
    var count = 0
}
