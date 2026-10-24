import AppKit
@testable import CmuxNextApp
import CmuxNextBridge
@testable import CmuxNextDaemon
import CmuxNextDesign
import Foundation
import Testing

/// The keyed finished status run follower (`followStatusRuns`) through its real path: one
/// observation per workspace record, the workspace set followed by its revision. A finished run
/// posts one notice; a workspace that joins after the start is followed; a record replaced under
/// its id (closed and added again in one batch) is followed as the new record; a workspace that
/// leaves is let go.
///
/// The test waits on what the follower does (each status it examines asks `behavior` once; each
/// notice it posts), never on time.
@MainActor @Suite(.timeLimit(.minutes(1))) struct StatusRunFollowerTests {
    /// Workspaces 1...`count` (`ws_N`, key `wN`), each one pane with one tab on surface N (`term_N`).
    private static func tree(_ count: Int, revision: UInt64 = 1) -> DaemonTree {
        DaemonTree(workspaceRevision: revision, workspaces: (1...count).map { Self.workspace($0) })
    }

    private static func workspace(_ index: Int) -> WorkspaceSnapshot {
        let id = UInt64(index)
        let pane = PaneSnapshot(id: PaneID(rawValue: id), tabs: [TabSnapshot(surface: SurfaceID(rawValue: id), terminalResourceID: ResourceID(rawValue: "term_\(index)"))])
        let screen = ScreenSnapshot(id: ScreenID(rawValue: id), layout: .leaf(PaneID(rawValue: id)), panes: [pane])
        return WorkspaceSnapshot(id: WorkspaceHandle(rawValue: id), key: WorkspaceKey(rawValue: "w\(index)"),
                                 resourceID: ResourceID(rawValue: "ws_\(index)"), name: "w\(index)", screens: [screen])
    }

    private static func store(_ count: Int) throws -> DaemonStore {
        _ = NSApplication.shared
        let store = DaemonStore()
        store.connectionState = .connected(try JSONDecoder().decode(DaemonIdentity.self, from: Data(
            #"{"app":"cmux-tui","protocol":1,"session":"status-follower","generation":"g1"}"#.utf8)))
        store.apply(snapshot: tree(count))
        let workspaces = (1...count).map { #"{"id":"ws_\#($0)"}"# }.joined(separator: ",")
        let statuses = (1...count).map { #"{"workspace_id":"ws_\#($0)","entries":[]}"# }.joined(separator: ",")
        let line = #"{"type":"stream_item","item":{"kind":"snapshot","snapshot":{"workspaces":["# + workspaces + #"],"terminals":[],"#
            + #""extra":{"state":{"workspace_status":["# + statuses + "]}}}}}"
        store.session.apply(try #require(SessionStreamItem.decode(Data(line.utf8))), in: store)
        return store
    }

    /// Writes workspace `index`'s `run:42` entry as the CLI does: busy, or finished after a minute.
    private static func run(_ index: Int, finished: Bool, in store: DaemonStore) throws {
        let state = finished ? #""state":"success","exit_code":0,"duration_ms":"60000","updated_at_ms":"2""# : #""state":"busy","updated_at_ms":"1""#
        let entry = #"{"key":"run:42","text":"Tests","target_terminal":"term_\#(index)",\#(state)}"#
        let line = #"{"type":"stream_item","item":{"kind":"delta","changes":[{"kind":"state_upsert","resource":"workspace_status","id":"ws_\#(index)","value":{"workspace_id":"ws_\#(index)","entries":["#
            + entry + "]}}]}}"
        store.session.apply(try #require(SessionStreamItem.decode(Data(line.utf8))), in: store)
    }

    /// A follower of `store` whose examined statuses and posted notices (by surface) the test reads.
    @MainActor private struct Follower {
        /// Held: the follower holds its service weakly and ends with it.
        let service: NotificationCenterService
        let task: Task<Void, Never>
        var examined: AsyncStream<Void>.Iterator
        var posted: AsyncStream<SurfaceID?>.Iterator

        init(_ store: DaemonStore, service: NotificationCenterService) {
            let (examined, examining) = AsyncStream<Void>.makeStream()
            let (posted, posting) = AsyncStream<SurfaceID?>.makeStream()
            var settings = StatusBehaviorSettings()
            settings.runNotifyMinimumSeconds = 10
            settings.runNotifyWhenVisible = false
            let behavior = settings
            self.service = service
            task = service.followStatusRuns(store, behavior: {
                examining.yield()
                return behavior
            }, visibility: { _ in .hidden }, post: { posting.yield($0.surface) })
            self.examined = examined.makeAsyncIterator()
            self.posted = posted.makeAsyncIterator()
        }

        mutating func examine(_ count: Int = 1) async {
            // A local copy: a nonisolated async `next()` cannot mutate a main-actor stored property.
            var iterator = examined
            for _ in 0..<count { _ = await iterator.next() }
            examined = iterator
        }

        /// The surface of the next notice the follower posts.
        mutating func nextNotice() async -> SurfaceID? {
            var iterator = posted
            defer { posted = iterator }
            return await iterator.next() ?? nil
        }

        /// Workspace `index`'s run goes busy (seen busy), then finishes; returns the next notice's surface.
        mutating func finish(_ index: Int, in store: DaemonStore) async throws -> SurfaceID? {
            try StatusRunFollowerTests.run(index, finished: false, in: store)
            await examine()
            try StatusRunFollowerTests.run(index, finished: true, in: store)
            return await nextNotice()
        }
    }

    @Test func aFinishedRunPostsExactlyOneNotice() async throws {
        let store = try Self.store(10)
        var follower = Follower(store, service: NotificationCenterService())
        defer { follower.task.cancel() }
        await follower.examine(10)
        let first = try await follower.finish(7, in: store)
        #expect(first == SurfaceID(rawValue: 7))
        // The next notice is workspace 3's: workspace 7's run posted once.
        let next = try await follower.finish(3, in: store)
        #expect(next == SurfaceID(rawValue: 3), "a second notice came before workspace 3's: \(String(describing: next))")
    }

    @Test func aWorkspaceAddedAfterTheStartIsFollowed() async throws {
        let store = try Self.store(3)
        var follower = Follower(store, service: NotificationCenterService())
        defer { follower.task.cancel() }
        await follower.examine(3)
        store.apply(snapshot: Self.tree(4, revision: 2))
        // Only the new workspace is examined: the three others keep their records and watches.
        await follower.examine()
        let notice = try await follower.finish(4, in: store)
        #expect(notice == SurfaceID(rawValue: 4))
    }

    @Test func aRecordReplacedUnderItsIdIsFollowedAsTheNewRecord() async throws {
        let store = try Self.store(3)
        var follower = Follower(store, service: NotificationCenterService())
        defer { follower.task.cancel() }
        await follower.examine(3)
        let old = try #require(store.workspace(key: WorkspaceKey(rawValue: "w2")))
        store.apply(batch: [
            DaemonEventEnvelope(sequence: 1, event: .workspaceClosed(WorkspaceDelta(workspace: WorkspaceHandle(rawValue: 2), index: nil,
                                                                                     entity: Self.workspace(2), workspaceRevision: 2))),
            DaemonEventEnvelope(sequence: 2, event: .workspaceAdded(WorkspaceDelta(workspace: WorkspaceHandle(rawValue: 2), index: 1,
                                                                                    entity: Self.workspace(2), workspaceRevision: 3))),
        ])
        try #require(store.workspace(key: WorkspaceKey(rawValue: "w2")) !== old, "the batch did not replace the record")
        // The follower lets the old record go and examines the new one.
        await follower.examine()
        let notice = try await follower.finish(2, in: store)
        #expect(notice == SurfaceID(rawValue: 2))
    }

    /// Workspace 3 leaves; its record then shows a run going busy and finishing (as a stale record
    /// would). A follower that kept its watch would post that run; the one that let go posts only
    /// workspace 1's run, interleaved with it.
    @Test func aWorkspaceThatLeavesIsLetGo() async throws {
        let store = try Self.store(3)
        var follower = Follower(store, service: NotificationCenterService())
        defer { follower.task.cancel() }
        await follower.examine(3)
        let left = try #require(store.workspace(key: WorkspaceKey(rawValue: "w3")))
        store.apply(snapshot: Self.tree(2, revision: 2))
        try #require(!store.workspaces.contains { $0 === left })
        left.applyState(ephemeral: false, status: try Self.status(3, finished: false), screenGroups: nil)
        try Self.run(1, finished: false, in: store)
        await follower.examine()
        left.applyState(ephemeral: false, status: try Self.status(3, finished: true), screenGroups: nil)
        try Self.run(1, finished: true, in: store)
        let first = await follower.nextNotice()
        #expect(first == SurfaceID(rawValue: 1), "the first notice was not workspace 1's run: \(String(describing: first))")
    }

    /// Workspace `index`'s status with its `run:42` entry, as ``run(_:finished:in:)`` writes it.
    private static func status(_ index: Int, finished: Bool) throws -> WorkspaceStatus {
        let state = finished ? #""state":"success","exit_code":0,"duration_ms":"60000","updated_at_ms":"2""# : #""state":"busy","updated_at_ms":"1""#
        let json = #"{"workspace_id":"ws_\#(index)","entries":[{"key":"run:42","text":"Tests","target_terminal":"term_\#(index)",\#(state)}]}"#
        return try JSONDecoder().decode(WorkspaceStatus.self, from: Data(json.utf8))
    }
}
