import AppKit
import CmuxNextActions
import CmuxNextBridge
@testable import CmuxNextApp
import CmuxNextDaemon
import Testing

/// A window keeps recently shown workspaces mounted (plans/cmux-next/
/// tab-lifecycle.md): switching back reuses the same content (no rebuild,
/// no re-attach), a parked workspace sends no focus topology, and the
/// budget and closing a workspace release them.
@MainActor
struct ParkedWorkspaceTests {
    static let keys = (1...3).map { WorkspaceKey(rawValue: "5c1d0a52-6d3f-4c55-9d53-8f1f4e0f2b0\($0)") }

    private static func services() -> AppServices {
        let services = ActionBindingCoverageTests.boundServices()
        services.windows.ordersWindowsIn = false
        let snapshots = keys.enumerated().map { index, key in
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: UInt64(index + 1)), key: key, name: "w\(index + 1)")
        }
        services.daemon.store.apply(snapshot: DaemonTree(workspaceRevision: 4, workspaces: snapshots))
        return services
    }

    private static func settle(_ condition: () -> Bool) async {
        for _ in 0..<500 where !condition() { await Task.yield() }
    }

    @Test func switchingBackReusesTheParkedContent() async throws {
        let services = Self.services()
        let window = try #require(services.windows.openWindow(workspaces: Self.keys.map(\.rawValue)))
        await Self.settle { window.content != nil }
        let first = try #require(window.content)
        services.windows.didActivate(window)
        #expect(services.registry.perform("nextSidebarTab", invocation: ActionInvocation()))
        await Self.settle { window.content !== first }
        #expect(window.parked.contains { $0 === first })
        #expect(first.isParked)
        #expect(first.layoutView.window == nil)
        #expect(services.registry.perform("prevSidebarTab", invocation: ActionInvocation()))
        await Self.settle { window.content === first }
        #expect(window.content === first)
        #expect(!first.isParked)
        #expect(first.layoutView.window === window.window)
        window.window?.close()
    }

    @Test func theBudgetReleasesTheOldestParkedWorkspace() async throws {
        let services = Self.services()
        let window = try #require(services.windows.openWindow(workspaces: Self.keys.map(\.rawValue)))
        await Self.settle { window.content != nil }
        services.windows.didActivate(window)
        for _ in 0..<2 {
            let before = window.content
            #expect(services.registry.perform("nextSidebarTab", invocation: ActionInvocation()))
            await Self.settle { window.content !== before }
        }
        #expect(window.parked.count == 2)
        window.setParkedBudget(WarmSetBudget(terminalCapacity: 4, parkedWorkspaces: 1, parkedPanes: 4))
        #expect(window.parked.count == 1)
        window.setParkedBudget(WarmSetBudget(terminalCapacity: 0, parkedWorkspaces: 0, parkedPanes: 0))
        #expect(window.parked.isEmpty)
        window.window?.close()
    }
}
