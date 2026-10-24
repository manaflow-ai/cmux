import AppKit
@testable import CmuxNextApp
import CmuxNextBridge
@testable import CmuxNextDaemon
import CmuxNextDesign
import Foundation
import Testing

/// The finished status run follower reads a workspace's first status in the step that follows it,
/// with its observation armed then (`ObservationStream.current`). A follower that armed it later
/// (a watch task's first read, hops after the workspace was listed) saw only what the status was
/// by then: a run that was busy when the follower started and finished in that gap was never seen
/// busy, so it never posted its notice.
@MainActor @Suite(.timeLimit(.minutes(1))) struct StatusRunFirstReadTests {
    /// Workspaces 1 and 2 (`ws_N`, key `wN`), each one pane with one tab on surface N (`term_N`),
    /// each with its `run:42` busy.
    private static func store() throws -> DaemonStore {
        _ = NSApplication.shared
        let store = DaemonStore()
        store.connectionState = .connected(try JSONDecoder().decode(DaemonIdentity.self, from: Data(
            #"{"app":"cmux-tui","protocol":1,"session":"status-first-read","generation":"g1"}"#.utf8)))
        store.apply(snapshot: DaemonTree(workspaceRevision: 1, workspaces: (1...2).map { index in
            let id = UInt64(index)
            let pane = PaneSnapshot(id: PaneID(rawValue: id), tabs: [TabSnapshot(surface: SurfaceID(rawValue: id), terminalResourceID: ResourceID(rawValue: "term_\(index)"))])
            let screen = ScreenSnapshot(id: ScreenID(rawValue: id), layout: .leaf(PaneID(rawValue: id)), panes: [pane])
            return WorkspaceSnapshot(id: WorkspaceHandle(rawValue: id), key: WorkspaceKey(rawValue: "w\(index)"),
                                     resourceID: ResourceID(rawValue: "ws_\(index)"), name: "w\(index)", screens: [screen])
        }))
        let line = #"{"type":"stream_item","item":{"kind":"snapshot","snapshot":{"workspaces":[{"id":"ws_1"},{"id":"ws_2"}],"terminals":[],"#
            + #""extra":{"state":{"workspace_status":["# + Self.status(1, finished: false) + "," + Self.status(2, finished: false) + "]}}}}}"
        store.session.apply(try #require(SessionStreamItem.decode(Data(line.utf8))), in: store)
        return store
    }

    /// Workspace `index`'s status with its `run:42` entry, as `cmux status run` writes it: busy, or
    /// finished after a minute.
    private static func status(_ index: Int, finished: Bool) -> String {
        let state = finished ? #""state":"success","exit_code":0,"duration_ms":"60000","updated_at_ms":"2""# : #""state":"busy","updated_at_ms":"1""#
        return #"{"workspace_id":"ws_\#(index)","entries":[{"key":"run:42","text":"Tests","target_terminal":"term_\#(index)",\#(state)}]}"#
    }

    private static func finish(_ index: Int, in store: DaemonStore) throws {
        let line = #"{"type":"stream_item","item":{"kind":"delta","changes":[{"kind":"state_upsert","resource":"workspace_status","id":"ws_\#(index)","value":"#
            + Self.status(index, finished: true) + "}]}}"
        store.session.apply(try #require(SessionStreamItem.decode(Data(line.utf8))), in: store)
    }

    @Test func aRunThatFinishesRightAfterTheFollowerStartsPostsItsNotice() async throws {
        let store = try Self.store()
        let service = NotificationCenterService()
        let (examined, examining) = AsyncStream<Void>.makeStream()
        let (posted, posting) = AsyncStream<SurfaceID?>.makeStream()
        var examinations = examined.makeAsyncIterator()
        var notices = posted.makeAsyncIterator()
        let behavior = StatusBehaviorSettings()
        let task = service.followStatusRuns(store, behavior: {
            examining.yield()
            return behavior
        }, visibility: { _ in .hidden }, post: { posting.yield($0.surface) })
        defer { task.cancel() }
        // The follower's first turn is already queued on the main actor; this test's next turn
        // queues behind it (the main actor runs its jobs in order). So workspace 1's run finishes
        // after the follower's first turn and before anything that turn queued: the gap between
        // following a workspace and a first read made later.
        await Task.yield()
        try Self.finish(1, in: store)
        // Both workspaces' first reads, then workspace 2's run finishes: the fence. Changes reach
        // the follower in order, so workspace 1's notice, when there is one, comes first.
        _ = await examinations.next()
        _ = await examinations.next()
        try Self.finish(2, in: store)
        let first = await notices.next() ?? nil
        try #require(first == SurfaceID(rawValue: 1), "the run that finished right after the follower started posted no notice: the first was \(String(describing: first))")
        let second = await notices.next() ?? nil
        #expect(second == SurfaceID(rawValue: 2), "workspace 1's run posted twice, or workspace 2's not at all: \(String(describing: second))")
    }
}
