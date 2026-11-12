import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import Foundation
import Testing

/// The tab moves a person asks the Command Palette for by name (user, 2026-11-11: "im in a tab and i want to move it
/// to right split"): Move Tab to Pane Right with no pane to the right makes that split, Move Tab to Window… moves the
/// tab into the workspace another window shows, and Duplicate Tab to New Split leaves the tab and puts its copy in a
/// new split. Each runs through the registry, as the palette, a key, a menu and `cmux tab …` do.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct TabMovePaletteMovesTests {
    /// Whether the linked catalog has `id` (Move Tab to Window… and Duplicate Tab to New Split come with the app FFI
    /// release after their catalog commit).
    private static func inCatalog(_ id: ActionID) -> Bool { ActionRegistry.standard().descriptor(for: id) != nil }

    /// A workspace whose one pane holds two terminals, shown in the active window, and the second terminal.
    private static func twoTabs(_ services: AppServices, _ connection: DaemonConnection) async throws -> (WorkspaceModel, PaneModel, TabModel) {
        let window = try #require(services.windows.active)
        let workspace = try await MoveToNewWindowTests.newWorkspace(services)
        window.state.showWorkspace(workspace.id)
        let source = try #require(workspace.screens.first?.panes.first)
        let created = try await connection.newTab(in: source.handle)
        try await PasswordManagerRouteTests.until({
            window.state.workspaceID == workspace.id && source.tabs.count == 2 && services.daemon.store.tab(surface: created.surface) != nil
        }, report: { "shows \(String(describing: window.state.workspaceID)), tabs \(source.tabs.count)" })
        return (workspace, source, try #require(services.daemon.store.tab(surface: created.surface)))
    }

    private static func onTab(_ tab: TabModel, _ arguments: [String: ActionValue] = [:]) -> ActionInvocation {
        ActionInvocation(target: ActionTargetRef(kind: .tab, id: tab.id), arguments: arguments, origin: .user)
    }

    /// At the screen's right edge, Move Tab to Pane Right makes the right split and the tab is its only tab.
    @Test func moveToPaneRightWithNoPaneThereMakesTheSplit() async throws {
        try await PasswordManagerRouteTests.withApp { services, connection in
            let (workspace, source, moved) = try await Self.twoTabs(services, connection)
            #expect(workspace.screens.flatMap(\.panes).count == 1)
            #expect(services.registry.perform("moveSurfaceToPaneRight", invocation: Self.onTab(moved)))
            try await PasswordManagerRouteTests.until({
                let panes = workspace.screens.flatMap(\.panes)
                return panes.count == 2 && source.tabs.count == 1 && panes.contains { $0 !== source && $0.tabs.map(\.id) == [moved.id] }
            }, report: { "panes \(workspace.screens.flatMap(\.panes).map { $0.tabs.map(\.id) })" })
        }
    }

    /// A tab alone in its pane has nothing to split from: the move is refused and the layout stays.
    @Test func aLoneTabAtTheEdgeStays() async throws {
        try await PasswordManagerRouteTests.withApp { services, _ in
            let window = try #require(services.windows.active)
            let workspace = try await MoveToNewWindowTests.newWorkspace(services)
            window.state.showWorkspace(workspace.id)
            let source = try #require(workspace.screens.first?.panes.first)
            let tab = try #require(source.tabs.first)
            _ = services.registry.perform("moveSurfaceToPaneLeft", invocation: Self.onTab(tab))
            #expect(workspace.screens.flatMap(\.panes).count == 1)
            #expect(source.tabs.map(\.id) == [tab.id])
        }
    }

    /// Move Tab to Window… puts the tab in the workspace the chosen window shows.
    @Test(.enabled("needs the app FFI with tab.moveToWindow") { await Self.inCatalog("tab.moveToWindow") })
    func moveToWindowLandsInThatWindowsWorkspace() async throws {
        try await PasswordManagerRouteTests.withApp { services, connection in
            let (_, source, moved) = try await Self.twoTabs(services, connection)
            let first = try #require(services.windows.active)
            #expect(services.registry.perform("newWindow", invocation: ActionInvocation(origin: .user)))
            try await PasswordManagerRouteTests.until({ services.windows.controllers.contains { $0 !== first && $0.state.workspaceID != nil } },
                                                      report: { "windows \(services.windows.controllers.map(\.state.workspaceID))" })
            let other = try #require(services.windows.controllers.first { $0 !== first })
            let target = try #require(other.state.workspaceID)
            let invocation = Self.onTab(moved, ["window": .target(ActionTargetRef(kind: .window, id: other.state.id))])
            #expect(services.registry.perform("tab.moveToWindow", invocation: invocation))
            try await PasswordManagerRouteTests.until({ services.workspaceID(ofTab: moved) == target && !source.tabs.contains { $0.id == moved.id } },
                                                      report: { "tab in \(String(describing: services.workspaceID(ofTab: moved))), want \(target)" })
        }
    }

    /// Duplicate Tab to New Split keeps the tab where it is and shows a copy in a new split.
    @Test(.enabled("needs the app FFI with tab.duplicateToNewSplit") { await Self.inCatalog("tab.duplicateToNewSplit") })
    func duplicateToNewSplitLeavesTheTabAndSplitsACopy() async throws {
        try await PasswordManagerRouteTests.withApp { services, connection in
            let (workspace, source, tab) = try await Self.twoTabs(services, connection)
            #expect(services.registry.perform("tab.duplicateToNewSplit", invocation: Self.onTab(tab)))
            try await PasswordManagerRouteTests.until({
                let panes = workspace.screens.flatMap(\.panes)
                return panes.count == 2 && source.tabs.count == 2 && source.tabs.contains { $0.id == tab.id }
                    && panes.contains { $0 !== source && $0.tabs.count == 1 && $0.tabs.first?.id != tab.id }
            }, report: { "panes \(workspace.screens.flatMap(\.panes).map { $0.tabs.map(\.id) })" })
        }
    }
}
