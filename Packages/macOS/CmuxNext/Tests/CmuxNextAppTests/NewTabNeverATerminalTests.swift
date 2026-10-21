import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextTabs
import Foundation
import Testing

/// cx-hvc57: a person's New Tab opens the New Tab page, never a terminal on its own (Leo
/// 2026-10-12), also where no tab decides a kind: Cmd-T in an empty workspace (no pane yet) and
/// the tab group editor's New Tab on a group with no tabs. Both opened a terminal before.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct NewTabNeverATerminalTests {
    /// This Mac's install id: with the bundled page and a daemon holding agent tabs, panes host the page.
    private static func hostsPages(_ services: AppServices) throws {
        services.agentTabs.localHost = AgentSessionRef.host(installID: "cn-hvc57")
        try #require(services.agentTabs.canHostChat, "this build has no New Tab page")
    }

    /// The tab is the New Tab page: a conversation tab of this Mac the agent tabs show as the page.
    private static func isNewTabPage(_ tab: TabModel, _ services: AppServices) -> Bool {
        tab.kind == .conversation && tab.agentSession != nil && services.agentTabs.isNewTabPage(tab.id)
    }

    @Test func cmdTInAnEmptyWorkspaceOpensTheNewTabPage() async throws {
        try await PasswordManagerRouteTests.withApp { services, connection in
            try Self.hostsPages(services)
            let window = try #require(services.windows.active)
            let created = try await connection.state.createWorkspace(name: "empty-hvc57", ephemeral: false, terminal: false, focus: true)
            try await PasswordManagerRouteTests.until { services.daemon.store.workspaces.contains { $0.resourceID == created.workspaceID } }
            let workspace = try #require(services.daemon.store.workspaces.first { $0.resourceID == created.workspaceID })
            services.windows.show(workspaceID: workspace.id, in: window.state)
            // The window swaps its content after the selection; Cmd-T acts on the content it shows.
            try await PasswordManagerRouteTests.until({ window.workspaceContent?.workspace.id == workspace.id && window.focusedPane == nil },
                                                      report: { "shown: \(window.workspaceContent?.workspace.id ?? "none")" })

            #expect(services.registry.perform("newTab.default", invocation: ActionInvocation(origin: .user)))
            @MainActor func tabs() -> [TabModel] {
                services.daemon.store.workspaces.first { $0.id == workspace.id }?.screens.flatMap { $0.panes }.flatMap { $0.tabs } ?? []
            }
            try await PasswordManagerRouteTests.until({ tabs().contains { Self.isNewTabPage($0, services) } || tabs().contains { $0.kind == .pty } },
                                                      report: { "tabs: \(tabs().map { "\($0.id) \($0.kind)" })" })
            #expect(tabs().count == 1)
            #expect(tabs().allSatisfy { Self.isNewTabPage($0, services) }, "tabs: \(tabs().map { "\($0.id) \($0.kind)" })")
        }
    }

    @Test func newTabOnATabGroupWithoutTabsOpensTheNewTabPage() async throws {
        try await PasswordManagerRouteTests.withApp { services, _ in
            try Self.hostsPages(services)
            let pane = try #require(services.windows.active?.focusedPane)
            let before = Set(pane.pane.tabs.map(\.id))
            // The group editor's New Tab on a group the strip lists no tab of.
            pane.handle(.group(.newTab("group-without-tabs")))
            @MainActor func added() -> [TabModel] {
                services.daemon.store.pane(pane.pane.handle)?.tabs.filter { !before.contains($0.id) } ?? []
            }
            try await PasswordManagerRouteTests.until({ added().contains { Self.isNewTabPage($0, services) || $0.kind == .pty } },
                                                      report: { "added: \(added().map { "\($0.id) \($0.kind)" })" })
            #expect(added().count == 1)
            #expect(added().allSatisfy { Self.isNewTabPage($0, services) }, "added: \(added().map { "\($0.id) \($0.kind)" })")
        }
    }
}
