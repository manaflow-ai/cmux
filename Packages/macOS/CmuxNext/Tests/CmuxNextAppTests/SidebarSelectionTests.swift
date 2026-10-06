import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextSidebar
import Testing

/// SIDEBAR-SELECTION-ONE-MODEL: the window state gives one sidebar selection
/// (the shown page's top item, else the shown workspace), and Cmd-Ctrl-] /
/// Cmd-Ctrl-[ walk one list from Home through the App Store into the
/// workspaces (Lawrence: "cmd ctrl [] can navigate between every single item").
@MainActor
struct SidebarSelectionTests {
    static let home = SidebarItem.topItem(LayoutItemID("itm_home"))
    static let store = SidebarItem.topItem(LayoutItemID("itm_app_store"))

    /// One window that lists the tree's workspace (so its sidebar has the row).
    static func window() async throws -> (AppServices, WindowController, WindowState) {
        let services = ActionBindingCoverageTests.boundServices()
        services.windows.ordersWindowsIn = false
        services.daemon.store.apply(snapshot: try ProviderTabOpenTests.tree(surfaces: [5]))
        let workspace = try #require(services.daemon.store.workspaces.first)
        let window = try #require(services.windows.openWindow(workspaces: [workspace.id]))
        services.windows.didActivate(window)
        await BrowserTabTests.settle { window.content != nil }
        return (services, window, window.state)
    }

    @Test func theSelectionIsThePagesItemElseTheWorkspace() {
        let layout = SidebarLayoutDocument.defaults
        #expect(SidebarNavigation.selectedItem(page: .home, workspace: "w", layout: layout) == Self.home)
        #expect(SidebarNavigation.selectedItem(page: .page(.appStore), workspace: "w", layout: layout) == Self.store)
        #expect(SidebarNavigation.selectedItem(page: nil, workspace: "w", layout: layout) == .workspace(CmuxNextSidebar.WorkspaceID("w")))
        #expect(SidebarNavigation.selectedItem(page: .page(.settings), workspace: "w", layout: layout) == nil,
                "a page with no top item selects no item")
    }

    @Test func nextAndPreviousCrossFromTopItemsIntoWorkspaces() async throws {
        let (services, window, state) = try await Self.window()
        let workspace = try #require(state.workspaceID)
        let model = window.sidebar.model
        await BrowserTabTests.settle { model.itemOrder.topItems.count == 2 && !model.itemOrder.rows.isEmpty }
        try #require(model.itemOrder.topItems == [Self.home, Self.store])
        _ = TopPages.show(.home, services: services, in: state)
        await BrowserTabTests.settle { model.selectedItem == Self.home }
        #expect(model.selectedItem == Self.home, "the Home page selects the Home item")

        _ = services.registry.perform("nextSidebarTab", invocation: ActionInvocation(origin: .user))
        #expect(state.page == .page(.appStore), "Cmd-Ctrl-] from Home reaches the App Store")
        await BrowserTabTests.settle { model.selectedItem == Self.store }
        _ = services.registry.perform("nextSidebarTab", invocation: ActionInvocation(origin: .user))
        #expect(state.page == nil && state.workspaceID == workspace, "then the first workspace")
        await BrowserTabTests.settle { model.selectedItem == .workspace(CmuxNextSidebar.WorkspaceID(workspace)) }
        _ = services.registry.perform("prevSidebarTab", invocation: ActionInvocation(origin: .user))
        #expect(state.page == .page(.appStore), "Cmd-Ctrl-[ from the first workspace reaches the App Store")
        window.teardown()
        withExtendedLifetime(services) {}
    }

    @Test func commandNumberCountsEveryItem() async throws {
        let (services, window, state) = try await Self.window()
        let workspace = try #require(state.workspaceID)
        let model = window.sidebar.model
        await BrowserTabTests.settle { model.itemOrder.topItems.count == 2 && !model.itemOrder.rows.isEmpty }
        func number(_ n: Int) { _ = services.registry.perform("selectWorkspaceByNumber", invocation: ActionInvocation(arguments: ["index": .int(n)], origin: .user)) }
        number(2)
        #expect(state.page == .page(.appStore), "Cmd-2 is the App Store")
        number(1)
        #expect(state.page == .home, "Cmd-1 is Home")
        number(3)
        #expect(state.page == nil && state.workspaceID == workspace, "Cmd-3 is the first workspace")
        window.teardown()
        withExtendedLifetime(services) {}
    }
}
