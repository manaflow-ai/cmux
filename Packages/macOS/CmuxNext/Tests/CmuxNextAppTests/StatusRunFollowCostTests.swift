import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import Foundation
import Testing

/// A status change costs the finished-run follower the workspace whose status changed, not the
/// session: a script that sets statuses in 50 workspaces (`cmux status set`, `cmux status run`)
/// must not make it scan every workspace's status on each change (CLAUDE.md "Go past Chrome where
/// cmux is scripted").
@MainActor struct StatusRunFollowCostTests {
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

    private static func settle() async {
        for _ in 0..<100 { await Task.yield() }
    }

    @Test(arguments: [50, 500])
    func oneStatusChangeVisitsOneWorkspace(sessionSize: Int) async throws {
        let store = try Self.store(sessionSize)
        let service = NotificationCenterService()
        let task = service.followStatusRuns(store)
        defer { task.cancel() }
        // The first pass reads every workspace's status once (it learns the runs that are busy now);
        // it is done when every workspace was seen.
        for _ in 0..<20_000 where service.statusRunVisits < sessionSize { await Task.yield() }
        await Self.settle()
        let before = service.statusRunVisits
        try Self.setStatus(7, text: "building", in: store)
        await Self.settle()
        let visited = service.statusRunVisits - before
        #expect(visited >= 1, "the follower did not see the change")
        #expect(visited <= 1, "one status change visited \(visited) workspaces in a \(sessionSize)-workspace session")
    }
}
