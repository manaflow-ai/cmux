import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextHomeEngine
@testable import CmuxNextSidebar
import Foundation
import Testing

/// cmux#27880: each window has its own Home. With two windows, Home clicked in the second one
/// (Cmd-Shift-N) brought the first window forward on its Home: the store has one home workspace
/// and a workspace lives in one window. Now the second window gets a Home of its own, in itself:
/// the same Chief view (Home's page in the pinned chat dock), with none of the first window's
/// panes or tabs, and the first window keeps its Home.
@MainActor @Suite(.serialized, .timeLimit(.minutes(4)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct HomePerWindowTests {
    private static func tabs(_ workspace: WorkspaceModel) -> [TabModel] { workspace.screens.flatMap(\.panes).flatMap(\.tabs) }

    /// A Home other than the store's: it holds Home's page.
    private static func isWindowHome(_ workspace: WorkspaceModel?) -> Bool {
        guard let workspace, workspace.kind != "home" else { return false }
        return tabs(workspace).contains { $0.page == HomeDock.page }
    }

    private static func show(_ services: AppServices, in window: WindowController) {
        services.keyWindowSource = { [weak window] in window?.window }
        #expect(services.windows.active === window, "the clicked window is not the active one")
        #expect(services.registry.perform("home.show", invocation: ActionInvocation(origin: .user)))
    }

    @Test func homeInASecondWindowIsThatWindowsOwn() async throws {
        try await PasswordManagerRouteTests.withApp { services, connection in
            let keyWindow = services.keyWindowSource
            defer { services.keyWindowSource = keyWindow }
            let (windowA, homeA) = try await HomeSplitKeysTests.showHome(services, connection)
            // Window A's Home has a column of its own right of the dock.
            var terminal = ActionInvocation(origin: .user)
            terminal.opensTerminal = true
            services.keyWindowSource = { [weak windowA] in windowA?.window }
            #expect(services.registry.perform("splitRight", invocation: terminal))
            try await PasswordManagerRouteTests.until({ HomeSplitKeysTests.panes(homeA).count == 2 },
                                                      report: { "window A's Home panes: \(HomeSplitKeysTests.panes(homeA).count)" })
            let tabsA = Set(Self.tabs(homeA).map(\.id))

            let idB = services.windows.newWindow()
            try await PasswordManagerRouteTests.until({
                services.windows.controller(for: idB) != nil && !services.windows.registry.members(of: idB).isEmpty
            }, within: .seconds(60), report: { "windows \(services.windows.controllers.map(\.state.id))" })
            let windowB = try #require(services.windows.controller(for: idB))

            // A double click: the second joins the Home the first is making.
            Self.show(services, in: windowB)
            Self.show(services, in: windowB)
            try await PasswordManagerRouteTests.until({
                Self.isWindowHome(windowB.state.workspaceID.flatMap(services.workspace(id:)))
            }, within: .seconds(60), report: {
                "window B shows \(String(describing: windowB.state.workspaceID)), A shows \(String(describing: windowA.state.workspaceID))"
            })
            let homeB = try #require(windowB.state.workspaceID.flatMap(services.workspace(id:)))
            let registry = services.windows.registry.value
            // Home in window B stays in window B; window A keeps its Home.
            #expect(homeB.id != homeA.id, "window B shows window A's Home")
            #expect(registry.owner(of: homeB.id) == idB)
            #expect(registry.owner(of: homeA.id) == windowA.state.id, "window A's Home moved")
            #expect(windowA.state.workspaceID == homeA.id, "window A left its Home")
            // Window B's Home holds Home's page, in the pinned chat dock, and nothing of window A's Home.
            try await PasswordManagerRouteTests.until({
                HomeDock.pageTab(in: homeB).map { placed in
                    placed.screen.columns.contains { $0.dock?.isPinned == true && $0.layout.paneIDs.contains(placed.pane.handle) }
                } == true
            }, within: .seconds(30), report: { "window B's Home: \(HomeSplitKeysTests.panes(homeB).count) pane(s)" })
            let tabsB = Self.tabs(homeB)
            #expect(tabsB.map(\.page) == [HomeDock.page], "window B's Home holds \(tabsB.map { "\($0.kind)" })")
            #expect(tabsA.isDisjoint(with: tabsB.map(\.id)), "window B's Home has window A's tabs")
            // Its sidebar selects the Home item and lists no row for it.
            #expect(windowB.sidebar.model.workspace(SidebarWorkspaceID(homeB.id)) == nil, "window B's Home is a workspace row")
            if case .topItem? = SidebarNavigation.current(in: windowB, services) {} else {
                Issue.record("window B's sidebar selects \(String(describing: SidebarNavigation.current(in: windowB, services)))")
            }

            // Home again in B is the same Home; Home in A is A's.
            Self.show(services, in: windowB)
            #expect(windowB.state.workspaceID == homeB.id)
            Self.show(services, in: windowA)
            #expect(windowA.state.workspaceID == homeA.id && windowB.state.workspaceID == homeB.id)
            let homes = services.daemon.store.workspaces.filter { Self.isWindowHome($0) }
            #expect(homes.map(\.id) == [homeB.id], "window homes: \(homes.map(\.id))")

            // The Chief chat is shared: each window's dock shows the Messages view of the one Home service.
            try await PasswordManagerRouteTests.until({ HomeDockTab.view(services)?.messages != nil },
                                                      report: { "window A's dock has no Messages view" })
            let dockA = try #require(HomeDockTab.view(services))
            services.keyWindowSource = { [weak windowB] in windowB?.window }
            try await PasswordManagerRouteTests.until({ HomeDockTab.view(services)?.messages != nil },
                                                      report: { "window B's dock has no Messages view" })
            let dockB = try #require(HomeDockTab.view(services))
            #expect(dockA !== dockB, "both windows draw one dock view")
            #expect(dockA.mode == .messages && dockB.mode == .messages)
            #expect(dockA.messages?.shown == dockB.messages?.shown, "the docks show different Chief conversations")
        }
    }
}
