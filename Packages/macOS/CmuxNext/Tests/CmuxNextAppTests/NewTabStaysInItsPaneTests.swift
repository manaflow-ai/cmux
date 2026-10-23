import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextSettings
@testable import CmuxNextTabs
import Foundation
import Testing

/// Leo 2026-10-21: "THIS ADDING TABS: IT SWITCHES AROUND AND DOESN'T REALLY GET ADDED", then "DEFAULT ON
/// THE RIGHT". Cmd-T, the strip's + and Option-+ in an agent chat's pane open the tab on its right by
/// default (`layout.linkPlacement`): in the pane there, right after that pane's selected tab, selected
/// and focused, with no other tab moving in either pane. With `same-pane` the tab stays in the chat's
/// pane, after its selected tab. Any other pane (a terminal's) keeps its new tab.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct NewTabStaysInItsPaneTests {
    @Test func cmdTInADockedChatOpensOnTheRightAfterTheStripsSelectedTab() async throws {
        try await addsOnTheRight(action: "newTab.default")
    }

    /// Option-click on the + (`StripNewTab.sameKindAction`, New <Kind> Tab) on a browser tab in the dock.
    @Test func optionPlusInADockedChatOpensOnTheRightAfterTheStripsSelectedTab() async throws {
        try await addsOnTheRight(action: StripNewTab.sameKindAction)
    }

    @Test func cmdTInADockedChatStaysThereWithSamePane() async throws {
        try await staysInTheDock(action: "newTab.default")
    }

    @Test func optionPlusInADockedChatStaysThereWithSamePane() async throws {
        try await staysInTheDock(action: StripNewTab.sameKindAction)
    }

    @Test func cmdTInATerminalPaneStaysInIt() async throws {
        try await PasswordManagerRouteTests.withApp { services, connection in
            services.agentTabs.localHost = AgentSessionRef.host(installID: "cn-new-tab-stays")
            try #require(services.agentTabs.canHostChat, "this build has no New Tab page")
            services.linkOpener.placement = { .splitRight }
            let window = try #require(services.windows.active)
            let pane = try #require(window.focusedPane)
            let store = services.daemon.store
            // The pane's first tab, then a terminal, then a page; the terminal is selected.
            let firstID = try #require(pane.orderedIDs.first?.rawValue)
            let terminal = try await connection.newTab(in: pane.pane.handle)
            try await PasswordManagerRouteTests.until { store.tab(surface: terminal.surface) != nil }
            let terminalID = try #require(store.tab(surface: terminal.surface)).id
            let page = try await Self.browserTab("https://example.com/c", in: pane, services: services, connection: connection)
            try await PasswordManagerRouteTests.until { pane.orderedIDs.map(\.rawValue) == [firstID, terminalID, page] }
            pane.select(TabID(terminalID))
            try #require(pane.selectedTab?.kind == .pty, "the selected tab is not a terminal")

            try Self.perform("newTab.default", on: pane, services: services)

            let after = try await Self.settled(pane, count: 4)
            #expect(after[0] == firstID && after[1] == terminalID && after[3] == page, "the new tab is not right after the selected one: \(after)")
            #expect(pane.stripModel.selectedID?.rawValue == after[2], "selected \(pane.stripModel.selectedID?.rawValue ?? "none"), strip \(after)")
        }
    }

    /// The default (`split-right`): the tab opens in the strip pane right of the chat dock.
    private func addsOnTheRight(action: ActionID) async throws {
        try await PasswordManagerRouteTests.withApp { services, connection in
            services.linkOpener.placement = { .splitRight }
            let (window, strip, dock, dockIDs) = try await Self.dockedChat(services: services, connection: connection)
            // The strip pane: its first tab, then a page; the first is selected.
            let stripFirstID = try #require(strip.orderedIDs.first?.rawValue)
            let page = try await Self.browserTab("https://example.com/c", in: strip, services: services, connection: connection)
            try await PasswordManagerRouteTests.until { strip.orderedIDs.map(\.rawValue) == [stripFirstID, page] }
            strip.select(TabID(stripFirstID))
            // Pressed in the chat: focus starts there, so the strip's focus below is the new tab's doing.
            let content = try #require(window.workspaceContent)
            PaneHandlers.focus(dock.layoutPaneID, in: content)
            try await PasswordManagerRouteTests.until({ window.focusedPane === dock }, report: { "focus did not reach the dock" })

            try Self.perform(action, on: dock, services: services)

            let after = try await Self.settled(strip)
            #expect(after.first == stripFirstID && after.last == page, "the new tab is not right after the strip's selected one: \(after)")
            #expect(strip.stripModel.selectedID?.rawValue == after[1], "selected \(strip.stripModel.selectedID?.rawValue ?? "none"), strip \(after)")
            #expect(window.focusedPane === strip, "focus is not in the strip pane")
            #expect(dock.orderedIDs.map(\.rawValue) == dockIDs, "the dock changed: \(dockIDs) -> \(dock.orderedIDs.map(\.rawValue))")
            #expect(dock.stripModel.selectedID?.rawValue == dockIDs.first, "the dock's selection changed")
        }
    }

    /// `same-pane`: the tab stays in the chat dock, right after its selected tab; the strip is unchanged.
    private func staysInTheDock(action: ActionID) async throws {
        try await PasswordManagerRouteTests.withApp { services, connection in
            services.linkOpener.placement = { .samePane }
            let (_, strip, dock, dockIDs) = try await Self.dockedChat(services: services, connection: connection)
            let stripBefore = strip.orderedIDs.map(\.rawValue)

            try Self.perform(action, on: dock, services: services)

            let after = try await Self.settled(dock)
            #expect(after.first == dockIDs.first && after.last == dockIDs.last, "the new tab is not right after the selected one: \(after)")
            #expect(dock.stripModel.selectedID?.rawValue == after[1], "selected \(dock.stripModel.selectedID?.rawValue ?? "none"), strip \(after)")
            #expect(strip.orderedIDs.map(\.rawValue) == stripBefore, "the main strip changed: \(stripBefore) -> \(strip.orderedIDs.map(\.rawValue))")
        }
    }

    /// Two pages in an agent chat dock left of the strip pane (which keeps its first tab), the first selected.
    private static func dockedChat(services: AppServices, connection: DaemonConnection) async throws
        -> (WindowController, PaneController, PaneController, [String]) {
        services.agentTabs.localHost = AgentSessionRef.host(installID: "cn-new-tab-stays")
        try #require(services.agentTabs.canHostChat, "this build has no New Tab page")
        let window = try #require(services.windows.active)
        let strip = try #require(window.focusedPane)
        let store = services.daemon.store
        let first = try await connection.newFrontendBrowserTab(url: "https://example.com/a", engine: .webkit,
                                                               in: strip.pane.handle, activate: false)
        try await PasswordManagerRouteTests.until { store.tab(surface: first.surface) != nil }
        let firstTab = try #require(store.tab(surface: first.surface))
        let firstID = firstTab.id
        let moved = await withCheckedContinuation { done in
            TabMoves.toNewDockColumn(firstTab, anchor: strip.pane, edge: .left,
                                     role: .agentChat, services: services) { done.resume(returning: $0) }
        }
        try #require(moved, "the page did not move into a chat dock")
        @MainActor func dock() -> PaneController? {
            window.workspaceContent?.panes.values.first { $0.pane.tabs.contains { $0.id == firstID } && $0 !== strip }
        }
        try await PasswordManagerRouteTests.until({ dock() != nil }, report: { "no dock pane holds \(firstID)" })
        let dockPane = try #require(dock())
        try #require(ChatDockRules.isChatDock(dockPane.pane, services: services), "the column is not an agent chat dock")
        try #require(dockPane.stripModel.showsNewTabButton, "an unpinned chat dock takes tabs")
        let secondID = try await browserTab("https://example.com/b", in: dockPane, services: services, connection: connection)
        try await PasswordManagerRouteTests.until { dockPane.orderedIDs.map(\.rawValue) == [firstID, secondID] }
        dockPane.select(TabID(firstID))
        try #require(dockPane.stripModel.selectedID?.rawValue == firstID)
        return (window, strip, dockPane, [firstID, secondID])
    }

    /// A WebKit page opened unselected in `pane`, by its tab id.
    private static func browserTab(_ url: String, in pane: PaneController, services: AppServices,
                                   connection: DaemonConnection) async throws -> String {
        let store = services.daemon.store
        let opened = try await connection.newFrontendBrowserTab(url: url, engine: .webkit, in: pane.pane.handle, activate: false)
        try await PasswordManagerRouteTests.until { store.tab(surface: opened.surface) != nil }
        return try #require(store.tab(surface: opened.surface)).id
    }

    /// Runs `action` on `pane` as the strip's + does (`StripNewTab.request`: a pane target, a person's).
    private static func perform(_ action: ActionID, on pane: PaneController, services: AppServices) throws {
        let target = ActionTargetRef(kind: .pane, id: pane.paneKey)
        #expect(services.registry.perform(action, invocation: ActionInvocation(target: target, origin: .user)))
    }

    /// `pane`'s tab ids once it lists `count` real tabs and holds them past the new-tab placement window.
    private static func settled(_ pane: PaneController, count: Int = 3) async throws -> [String] {
        @MainActor func order() -> [String] { pane.orderedIDs.map(\.rawValue) }
        try await PasswordManagerRouteTests.until({ order().count == count && !order().contains(where: ProvisionalTab.isProvisional) },
                                                  report: { "strip: \(order())" })
        try await Task.sleep(for: .seconds(1))
        let after = order()
        try #require(after.count == count, "strip: \(after)")
        return after
    }
}
