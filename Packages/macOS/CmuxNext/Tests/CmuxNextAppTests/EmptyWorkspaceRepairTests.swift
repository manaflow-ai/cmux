@testable import CmuxNextApp
@testable import CmuxNextDaemon
import Testing

@MainActor struct EmptyWorkspaceRepairTests {
    private enum TestError: Error {
        case transientCloseFailure
    }

    private static func workspace(_ key: WorkspaceKey, withPane: Bool) -> WorkspaceModel {
        let pane = PaneSnapshot(id: 1, tabs: [TabSnapshot(surface: 1, title: "~")])
        let screen = ScreenSnapshot(
            id: 1,
            layout: .leaf(1),
            panes: withPane ? [pane] : []
        )
        return WorkspaceModel(WorkspaceSnapshot(
            id: 1,
            key: key,
            name: "empty",
            screens: [screen]
        ))
    }

    private static func drainTasks() async {
        for _ in 0..<20 { await Task.yield() }
    }

    @Test func anEmptyWorkspaceRetriesCleanupAfterATransientCloseFailure() async {
        let daemon = DaemonService()
        let repair = EmptyWorkspaceRepair(daemon: daemon)
        let key = WorkspaceKey(rawValue: "workspace-under-test")
        let populated = Self.workspace(key, withPane: true)
        let empty = Self.workspace(key, withPane: false)
        var closeAttempts = 0

        repair.epoch = { 1 }
        repair.isLive = { true }
        repair.canCreate = { true }
        repair.cause = { _ in .tabClosed }
        repair.close = { _ in
            closeAttempts += 1
            if closeAttempts == 1 { throw TestError.transientCloseFailure }
        }

        repair.check(populated, created: { _ in })
        repair.check(empty, created: { _ in })
        await Self.drainTasks()
        #expect(closeAttempts == 1)

        // A later store update gives the owner another chance to remove the
        // still-empty workspace after the transient daemon failure.
        repair.check(empty, created: { _ in })
        await Self.drainTasks()
        #expect(closeAttempts == 2)
    }
}
