import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextTabs
import Foundation
import Testing

/// Leo 2026-10-21: a link clicked in a chat opened its github.com tab without the focus, so his
/// Cmd-W closed the chat instead of the tab. As in Chrome: a plain click's tab takes the focus,
/// Cmd-W closes that tab (the focused one), and closing it gives the focus back to where the link
/// was clicked. Runs ``LinkOpener`` (every clicked link's path) and the app's Close Tab against a
/// same-tree cmux-tui daemon; the page the link is clicked in is the window's first terminal.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct ClickedLinkFocusTests {
    static let link = URL(string: "https://github.com/manaflow-ai/cmux/pull/1")!

    /// The link's tab opens in the source's own pane (the default for a link in a page): the source
    /// pane keeps the focus with the new tab selected, and its close selects the source tab again,
    /// not the tab after it.
    @Test func aLinksTabInItsPaneTakesTheFocusAndItsCloseSelectsTheSourceAgain() async throws {
        try await PinnedPageTests.withApp { services, connection in
            let store = services.daemon.store
            let content = try #require(services.windows.active?.workspaceContent)
            let model = try #require(store.workspaces.first?.screens.first?.panes.first)
            let pane = try #require(services.paneController(for: model))
            let source = try #require(model.tabs.first?.id)
            // A tab after the source: a close that takes the next or previous tab lands there.
            let other = try await connection.newFrontendBrowserTab(url: "https://example.com/other", engine: .webkit,
                                                                   in: model.handle, activate: false)
            try await PinnedPageTests.until({ store.tab(surface: other.surface).map { pane.orderedIDs.map(\.rawValue).contains($0.id) } == true })
            pane.select(TabID(source))
            PaneHandlers.focus(pane.layoutPaneID, in: content)
            try await PinnedPageTests.until({ content.focusedPane === pane && pane.stripModel.selectedID?.rawValue == source })

            let opened = try await Self.click(services, from: pane)
            try await PinnedPageTests.until({ pane.stripModel.selectedID?.rawValue == opened && content.focusedPane === pane },
                                            report: { Self.describe(content, opened) })

            // Cmd-W: the link's tab closes, the source stays.
            #expect(services.registry.perform("closeTab", invocation: ActionInvocation(origin: .user)))
            try await PinnedPageTests.until({ store.tab(id: opened) == nil }, report: { "the link's tab did not close" })
            #expect(store.tab(id: source) != nil, "Cmd-W closed the page the link was clicked in")
            try await PinnedPageTests.until({ pane.stripModel.selectedID?.rawValue == source && content.focusedPane === pane },
                                            report: { "after the close: " + Self.describe(content, source) })
        }
    }

    /// The link's tab opens in the pane right of the source (a terminal's Cmd-click, Home's dock):
    /// that pane takes the focus, Cmd-W closes the link's tab there, and the focus goes back to the
    /// source pane, not to the other tab of the link's pane.
    @Test func aLinksTabInAnotherPaneTakesTheFocusAndItsCloseGivesItBack() async throws {
        try await PinnedPageTests.withApp { services, _ in
            let store = services.daemon.store
            let content = try #require(services.windows.active?.workspaceContent)
            let model = try #require(store.workspaces.first?.screens.first?.panes.first)
            let pane = try #require(services.paneController(for: model))
            let source = try #require(model.tabs.first?.id)
            let panes = Set(content.panes.keys)
            #expect(services.registry.perform("splitRight", invocation: ActionInvocation(origin: .user)))
            try await PinnedPageTests.until({ content.panes.keys.contains { !panes.contains($0) } })
            let right = try #require(content.panes.first { !panes.contains($0.key) }?.value)
            try await PinnedPageTests.until({ !right.pane.tabs.isEmpty })
            PaneHandlers.focus(pane.layoutPaneID, in: content)
            try await PinnedPageTests.until({ content.focusedPane === pane })
            services.linkOpener.placement = { .splitRight }

            let opened = try await Self.click(services, from: pane, cmdClick: true)
            try await PinnedPageTests.until({ store.tab(id: opened).map { _ in right.pane.tabs.contains { $0.id == opened } } == true },
                                            report: { "the link's tab is not in the pane on the right" })
            try await PinnedPageTests.until({ content.focusedPane === right && right.stripModel.selectedID?.rawValue == opened },
                                            report: { Self.describe(content, opened) })

            #expect(services.registry.perform("closeTab", invocation: ActionInvocation(origin: .user)))
            try await PinnedPageTests.until({ store.tab(id: opened) == nil }, report: { "the link's tab did not close" })
            #expect(store.tab(id: source) != nil, "Cmd-W closed the page the link was clicked in")
            try await PinnedPageTests.until({ content.focusedPane === pane },
                                            report: { "after the close: " + Self.describe(content, source) })
        }
    }

    /// Opens the link from `pane` as a click does and returns the new tab's id once the store has it.
    private static func click(_ services: AppServices, from pane: PaneController, cmdClick: Bool = false) async throws -> String {
        let store = services.daemon.store
        let before = Set(store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs).map(\.id))
        services.linkOpener.openWeb(link, from: pane, background: false, cmdClick: cmdClick)
        @MainActor func opened() -> String? {
            store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs).first { !before.contains($0.id) }?.id
        }
        try await PinnedPageTests.until({ opened() != nil }, report: { "the link opened no tab" })
        return try #require(opened())
    }

    private static func describe(_ content: WorkspaceContentController, _ tab: String) -> String {
        let focused = content.focusedPane
        return "focused pane \(String(describing: focused?.layoutPaneID)) selects \(String(describing: focused?.stripModel.selectedID?.rawValue)), wanted \(tab)"
    }
}
