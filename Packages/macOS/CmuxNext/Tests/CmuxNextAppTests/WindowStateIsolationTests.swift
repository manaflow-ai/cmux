import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import Testing

/// Each window owns its state (user requirement 2026-09-29): two windows
/// keep separate selections, sidebars, and screen switchers; an action
/// aimed at one window never changes another; membership transitions touch
/// only the windows involved; the last workspace leaving a window closes
/// it, except the only window, which shows the empty state. Windows are
/// created but never put on screen (`ordersWindowsIn = false`).
@MainActor
struct WindowStateIsolationTests {
    static let keys = (1...4).map { WorkspaceKey(rawValue: "0b6c4a52-6d3f-4c55-9d53-8f1f4e0f1a0\($0)") }

    private static func services(workspaces count: Int = 4) -> AppServices {
        let services = ActionBindingCoverageTests.boundServices()
        services.windows.ordersWindowsIn = false
        apply(services, keys: Array(keys.prefix(count)))
        return services
    }

    private static func apply(_ services: AppServices, keys: [WorkspaceKey]) {
        let snapshots = keys.enumerated().map { index, key in
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: UInt64(index + 1)), key: key, name: "w\(index + 1)")
        }
        services.daemon.store.apply(snapshot: DaemonTree(workspaceRevision: UInt64(keys.count + 1), workspaces: snapshots))
    }

    private static func id(_ index: Int) -> String { keys[index - 1].rawValue }

    private static func settle(_ condition: () -> Bool) async {
        for _ in 0..<500 where !condition() { await Task.yield() }
    }

    private static func sidebarIDs(_ controller: WindowController) -> Set<String> {
        Set(controller.sidebar.model.sections.flatMap(\.workspaces).map(\.id.rawValue))
    }

    private static func run(_ services: AppServices, _ id: ActionID, _ invocation: ActionInvocation = ActionInvocation()) {
        #expect(services.registry.perform(id, invocation: invocation))
    }

    @Test func twoWindowsKeepTheirOwnSelectionAndSidebar() async throws {
        let services = Self.services()
        let a = try #require(services.windows.openWindow(workspaces: [Self.id(1), Self.id(2)]))
        let b = try #require(services.windows.openWindow(workspaces: [Self.id(3), Self.id(4)]))
        #expect(a.state.workspaceID == Self.id(1))
        #expect(b.state.workspaceID == Self.id(3))
        await Self.settle { Self.sidebarIDs(a).count == 2 && Self.sidebarIDs(b).count == 2 }
        #expect(Self.sidebarIDs(a) == [Self.id(1), Self.id(2)])
        #expect(Self.sidebarIDs(b) == [Self.id(3), Self.id(4)])
        #expect(services.windows.registry.value.violations().isEmpty)
        for controller in [a, b] { controller.window?.close() }
    }

    @Test func actionsOnTheActiveWindowLeaveTheOtherAlone() async throws {
        let services = Self.services()
        let a = try #require(services.windows.openWindow(workspaces: [Self.id(1), Self.id(2)]))
        let b = try #require(services.windows.openWindow(workspaces: [Self.id(3), Self.id(4)]))
        await Self.settle { a.content != nil && b.content != nil && Self.sidebarIDs(a).count == 2 }
        services.windows.didActivate(a)

        Self.run(services, "nextSidebarTab")
        #expect(a.state.workspaceID == Self.id(2))
        #expect(b.state.workspaceID == Self.id(3))

        await Self.settle { a.content?.workspace.id == Self.id(2) }
        Self.run(services, "screen.toggleSwitcher")
        #expect(a.state.showsScreenSwitcher)
        #expect(!b.state.showsScreenSwitcher)

        Self.run(services, "toggleSidebar")
        #expect(a.sidebar.model.presentation != b.sidebar.model.presentation)

        // The switcher stays with the window across a workspace switch.
        Self.run(services, "prevSidebarTab")
        await Self.settle { a.content?.workspace.id == Self.id(1) }
        #expect(a.content?.layoutModel.showsScreenSwitcher == true)
        for controller in [a, b] { controller.window?.close() }
    }

    @Test func movingAWorkspaceTouchesOnlyTheTwoWindows() throws {
        let services = Self.services()
        let a = try #require(services.windows.openWindow(workspaces: [Self.id(1), Self.id(2)]))
        let b = try #require(services.windows.openWindow(workspaces: [Self.id(3)]))
        let c = try #require(services.windows.openWindow(workspaces: [Self.id(4)]))
        c.state.showsScreenSwitcher = true
        services.windows.didActivate(a)
        Self.run(services, "moveWorkspaceToWindow", ActionInvocation(
            target: ActionTargetRef(kind: .workspace, id: Self.id(2)),
            arguments: ["window": .target(ActionTargetRef(kind: .window, id: b.state.id))]))
        let registry = services.windows.registry
        #expect(registry.members(of: a.state.id) == [Self.id(1)])
        #expect(registry.members(of: b.state.id) == [Self.id(3), Self.id(2)])
        #expect(registry.members(of: c.state.id) == [Self.id(4)])
        #expect(b.state.workspaceID == Self.id(2))
        #expect(a.state.workspaceID == Self.id(1))
        #expect(c.state.workspaceID == Self.id(4) && c.state.showsScreenSwitcher)
        #expect(registry.value.violations().isEmpty)
        for controller in [a, b, c] { controller.window?.close() }
    }

    @Test func theLastWorkspaceLeavingAWindowClosesIt() throws {
        let services = Self.services()
        let a = try #require(services.windows.openWindow(workspaces: [Self.id(1)]))
        let b = try #require(services.windows.openWindow(workspaces: [Self.id(2)]))
        services.windows.moveWorkspaces([Self.id(2)], toWindow: a.state.id)
        #expect(services.windows.controllers.map(\.state.id) == [a.state.id])
        #expect(services.windows.registry.value.window(b.state.id) == nil)
        #expect(services.windows.states[b.state.id] == nil)
        #expect(a.state.workspaceID == Self.id(2))
        a.window?.close()
    }

    @Test func tearingOffOpensAWindowAndClosingItHandsWorkspacesBack() throws {
        let services = Self.services()
        let a = try #require(services.windows.openWindow(workspaces: [Self.id(1), Self.id(2), Self.id(3)]))
        services.windows.didActivate(a)
        Self.run(services, "moveWorkspaceToNewWindow", ActionInvocation(target: ActionTargetRef(kind: .workspace, id: Self.id(3))))
        let torn = try #require(services.windows.controllers.first { $0 !== a })
        #expect(services.windows.registry.members(of: torn.state.id) == [Self.id(3)])
        #expect(torn.state.workspaceID == Self.id(3))
        // The user closes the torn-off window: its workspace returns, no terminal ends.
        services.windows.didActivate(a)
        torn.window?.close()
        #expect(services.windows.registry.members(of: a.state.id) == [Self.id(1), Self.id(2), Self.id(3)])
        #expect(services.windows.controllers.count == 1)
        a.window?.close()
    }

    @Test func theOnlyWindowShowsTheEmptyStateWhenItsWorkspacesClose() async throws {
        let services = Self.services(workspaces: 1)
        let a = try #require(services.windows.openWindow(workspaces: [Self.id(1)]))
        services.windows.reconcileMembership()
        Self.apply(services, keys: [])
        services.windows.reconcileMembership()
        #expect(services.windows.controllers.map(\.state.id) == [a.state.id])
        #expect(services.windows.registry.members(of: a.state.id).isEmpty)
        #expect(a.state.workspaceID == nil)
        await Self.settle { a.root.content is EmptyWindowView }
        #expect(a.root.content is EmptyWindowView)
        a.window?.close()
    }
}
