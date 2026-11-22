import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import Testing

/// Invariant (tag nxthm, a lost workspace during rapid switching): switching
/// workspaces never changes how many there are. Rapid next/previous switches
/// through many workspaces, past the parked budget, close nothing and leave
/// the window's and the daemon's workspace lists as they were.
@MainActor
struct WorkspaceSwitchInvariantTests {
    static let keys = (10...29).map { WorkspaceKey(rawValue: "5c1d0a52-6d3f-4c55-9d53-8f1f4e0f2b\($0)") }

    private static func settle(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() { await Task.yield() }
    }

    @Test func rapidSwitchesNeverChangeTheWorkspaceCount() async throws {
        let services = ActionBindingCoverageTests.boundServices()
        services.windows.ordersWindowsIn = false
        let snapshots = Self.keys.enumerated().map { index, key in
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: UInt64(index + 1)), key: key, name: "w\(index + 1)")
        }
        services.daemon.store.apply(snapshot: DaemonTree(workspaceRevision: 4, workspaces: snapshots))
        var closed: [WorkspaceKey] = []
        services.emptyWorkspaces.canCreate = { true }
        services.emptyWorkspaces.create = { _ in nil }
        services.emptyWorkspaces.close = { closed.append($0) }
        let window = try #require(services.windows.openWindow(workspaces: Self.keys.map(\.rawValue)))
        await Self.settle { window.content != nil }
        services.windows.didActivate(window)
        let members = services.windows.registry.members(of: window.state.id)
        for step in 0..<60 {
            #expect(services.registry.perform(step % 7 == 6 ? "prevSidebarTab" : "nextSidebarTab", invocation: ActionInvocation()))
            if step % 5 == 0 { await Task.yield() }
        }
        await Self.settle { false }
        #expect(closed.isEmpty)
        #expect(services.daemon.store.workspaces.count == Self.keys.count)
        #expect(services.windows.registry.members(of: window.state.id) == members)
        window.window?.close()
    }
}
