import AppKit
import CmuxNextActions
import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextFocus
import CmuxNextPages
import CmuxNextTabs
import Foundation
import Testing
import WebKit

/// Leo 2026-10-21: a link clicked in a chat opened its github.com tab without the focus, so his
/// Cmd-W closed the chat instead of the tab. As in Chrome: a plain click's tab takes the focus,
/// Cmd-W closes that tab (the focused one), and closing it gives the focus back to where the link
/// was clicked. Anything a person clicks takes the focus; only an agent's own open stays in the
/// background. Runs ``LinkOpener`` (every clicked link's path), the chat header's beside opens and
/// the app's Close Tab against a same-tree cmux-tui daemon; the page the link is clicked in is the
/// window's first terminal.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct ClickedLinkFocusTests {
    static let link = URL(string: "https://github.com/manaflow-ai/cmux/pull/1")!

    /// The link's tab opens in the source's own pane (Open Links and Files set to Same Pane): the source
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

            services.linkOpener.placement = { .samePane }
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

    /// The link's tab opens in the pane right of the source (the default for every link, Home's dock):
    /// that pane takes the focus and Cmd-W closes the link's tab there. The pane still has a tab, so
    /// the focus stays in it, on that tab: a second Cmd-W must close in the same pane, never the
    /// source (Leo 2026-10-21, ``CloseTabKeepsPaneTests``). Only a close that empties the pane gives
    /// the focus back (``theHeadersPreviewBesideThePageTakesTheFocusAndItsCloseGivesItBack``).
    @Test func aLinksTabInAnotherPaneTakesTheFocusAndItsCloseKeepsItInThatPane() async throws {
        try await PinnedPageTests.withApp { services, _ in
            let store = services.daemon.store
            let content = try #require(services.windows.active?.workspaceContent)
            let model = try #require(store.workspaces.first?.screens.first?.panes.first)
            let pane = try #require(services.paneController(for: model))
            let source = try #require(model.tabs.first?.id)
            let right = try await Self.splitRight(services, content)
            PaneHandlers.focus(pane.layoutPaneID, in: content)
            try await PinnedPageTests.until({ content.focusedPane === pane })
            services.linkOpener.placement = { .splitRight }

            let opened = try await Self.click(services, from: pane)
            try await PinnedPageTests.until({ store.tab(id: opened).map { _ in right.pane.tabs.contains { $0.id == opened } } == true },
                                            report: { "the link's tab is not in the pane on the right" })
            // The pane on the right by what it holds: the focus may have moved to another pane by now.
            try await PinnedPageTests.until({
                content.focusedPane !== pane && content.focusedPane?.pane.tabs.contains { $0.id == opened } == true
                    && content.focusedPane?.stripModel.selectedID?.rawValue == opened
            }, report: { Self.describe(content, opened) })

            let left = try #require(right.pane.tabs.first { $0.id != opened }?.id, "the pane on the right has no other tab")
            #expect(services.registry.perform("closeTab", invocation: ActionInvocation(origin: .user)))
            try await PinnedPageTests.until({ store.tab(id: opened) == nil }, report: { "the link's tab did not close" })
            #expect(store.tab(id: source) != nil, "Cmd-W closed the page the link was clicked in")
            try await PinnedPageTests.until({ content.focusedPane?.stripModel.selectedID?.rawValue == left },
                                            report: { "after the close: " + Self.describe(content, left) })
            #expect(content.focusedPane !== pane, "the close gave the focus back to the source while its pane still had a tab")
        }
    }

    /// The same link clicked again (an agent chat's PR link or card, Austin 2026-10-25: eleven tabs of
    /// one PR in the pane on the right) selects and focuses the tab the pane on the right already has
    /// for it, never a second tab of the same page.
    @Test func theSameLinkClickedAgainSelectsItsTabOnTheRight() async throws {
        try await PinnedPageTests.withApp { services, connection in
            let store = services.daemon.store
            let content = try #require(services.windows.active?.workspaceContent)
            let model = try #require(store.workspaces.first?.screens.first?.panes.first)
            let pane = try #require(services.paneController(for: model))
            let right = try await Self.splitRight(services, content)
            PaneHandlers.focus(pane.layoutPaneID, in: content)
            try await PinnedPageTests.until({ content.focusedPane === pane })
            services.linkOpener.placement = { .splitRight }

            let opened = try await Self.click(services, from: pane)
            try await PinnedPageTests.until({ right.pane.tabs.contains { $0.id == opened } && Self.shownURL(services, opened) != nil },
                                            report: { "the link's tab is not on the right with its page" })
            // Another tab is selected there, and the focus is back in the chat.
            let other = try await connection.newFrontendBrowserTab(url: "https://example.com/other", engine: .webkit,
                                                                   in: right.pane.handle, activate: false)
            try await PinnedPageTests.until({ store.tab(surface: other.surface).map { right.orderedIDs.map(\.rawValue).contains($0.id) } == true })
            let otherID = try #require(store.tab(surface: other.surface)?.id)
            right.select(TabID(otherID))
            PaneHandlers.focus(pane.layoutPaneID, in: content)
            try await PinnedPageTests.until({ content.focusedPane === pane && right.stripModel.selectedID?.rawValue == otherID })

            let before = Set(store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs).map(\.id))
            #expect(services.linkOpener.openWeb(Self.link, from: pane, background: false, reusesTab: true))
            try await PinnedPageTests.until({ content.focusedPane === right && right.stripModel.selectedID?.rawValue == opened },
                                            report: { Self.describe(content, opened) })
            let after = Set(store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs).map(\.id))
            #expect(after.subtracting(before).isEmpty, "the second click opened another tab of the same page: \(after.subtracting(before))")
        }
    }

    /// A chip clicked in an agent chat goes through ``LinkRouter`` (the page's link navigation), not
    /// the card's Open: clicked again, it too selects the tab the pane on the right has for the page.
    /// The dogfood of the first fix found this path still opening a tab per click.
    @Test func aChatChipClickedAgainSelectsItsTabOnTheRight() async throws {
        try await PinnedPageTests.withApp { services, _ in
            let store = services.daemon.store
            let content = try #require(services.windows.active?.workspaceContent)
            let model = try #require(store.workspaces.first?.screens.first?.panes.first)
            let pane = try #require(services.paneController(for: model))
            let right = try await Self.splitRight(services, content)
            try await PinnedPageTests.until({ Self.page(in: pane.view) != nil }, report: { "the source pane shows no agent page" })
            let chat = try #require(pane.currentTabKey)
            #expect(services.agentTabs.isAgentTab(chat), "the source tab is not an agent chat")
            PaneHandlers.focus(pane.layoutPaneID, in: content)
            try await PinnedPageTests.until({ content.focusedPane === pane })
            services.linkOpener.placement = { .splitRight }
            let tabs = { Set(store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs).map(\.id)) }

            let before = tabs()
            LinkRouter.shared.openInCmux(Self.link, false, chat)
            let opened = { tabs().subtracting(before).first { !ProvisionalTab.isProvisional($0) } }
            try await PinnedPageTests.until({ opened().map { id in right.pane.tabs.contains { $0.id == id } && Self.shownURL(services, id) != nil } == true },
                                            report: { "the chip's tab is not on the right with its page" })
            let first = try #require(opened())
            PaneHandlers.focus(pane.layoutPaneID, in: content)
            try await PinnedPageTests.until({ content.focusedPane === pane })

            let again = tabs()
            LinkRouter.shared.openInCmux(Self.link, false, chat)
            try await PinnedPageTests.until({ content.focusedPane === right && right.stripModel.selectedID?.rawValue == first },
                                            report: { Self.describe(content, first) })
            #expect(tabs().subtracting(again).isEmpty, "the second chip click opened another tab of the same page: \(tabs().subtracting(again))")
        }
    }

    /// A link clicked while the agent's own beside open is in flight (Leo's chat was mid-turn): the
    /// click is the person's and keeps the focus and the selection; the agent's tab, reported after
    /// it, lands unselected instead of replacing the clicked link's tab in the focused pane.
    @Test func aClickWhileAnAgentsOpenIsInFlightKeepsItsFocus() async throws {
        try await PinnedPageTests.withApp { services, connection in
            let store = services.daemon.store
            let content = try #require(services.windows.active?.workspaceContent)
            let model = try #require(store.workspaces.first?.screens.first?.panes.first)
            let pane = try #require(services.paneController(for: model))
            let right = try await Self.splitRight(services, content)
            // The agent's tab, made in the column right of its chat and not reported to the placement yet.
            let agents = try await connection.newFrontendBrowserTab(url: "https://example.com/agent", engine: .webkit,
                                                                    in: right.pane.handle, activate: false)
            try await PinnedPageTests.until({ store.tab(surface: agents.surface) != nil })
            PaneHandlers.focus(pane.layoutPaneID, in: content)
            try await PinnedPageTests.until({ content.focusedPane === pane })
            var invocation = ActionInvocation(target: ActionTargetRef(kind: .pane, id: right.paneKey), origin: .cli)
            invocation.besideCaller = true
            let agentPlaced = AgentBesidePlacement.placed(invocation, in: right, then: nil)

            services.linkOpener.placement = { .splitRight }
            let opened = try await Self.click(services, from: pane)
            let shown = { content.panes[right.layoutPaneID] ?? right }
            try await PinnedPageTests.until({ content.focusedPane === shown() && shown().stripModel.selectedID?.rawValue == opened },
                                            report: { Self.describe(content, opened) })
            agentPlaced(agents.surface)
            try await PinnedPageTests.until({ shown().pendingSelectSurface == nil && right.pendingSelectSurface == nil })
            #expect(content.focusedPane === shown(), "the agent's open took the focus from the clicked link")
            #expect(shown().stripModel.selectedID?.rawValue == opened, "the agent's tab replaced the clicked link's tab: \(Self.describe(content, opened))")
        }
    }

    /// The page a link is clicked in asks for the keyboard by itself (WebKit's `makeFirstResponder`,
    /// its composer's own focus) while the pane change that lands the link's tab is still queued.
    /// The window judged the ask against the focus before that change and let the page have it; the
    /// queued change, reduced first, put the focus on the link's tab, and the page's report took it
    /// straight back: the link's tab showed selected with the keyboard still in the page (four in
    /// eight runs of the click tests above).
    @Test func aPagesOwnFocusAskLosesToAQueuedLinkTabFocus() async throws {
        try await PinnedPageTests.withApp { services, _ in
            let store = services.daemon.store
            let content = try #require(services.windows.active?.workspaceContent)
            let window = try #require(services.windows.active?.window)
            let model = try #require(store.workspaces.first?.screens.first?.panes.first)
            let pane = try #require(services.paneController(for: model))
            let right = try await Self.splitRight(services, content)
            try await PinnedPageTests.until({ Self.page(in: pane.view) != nil }, report: { "the source pane shows no agent page" })
            let page = try #require(Self.page(in: pane.view))
            PaneHandlers.focus(pane.layoutPaneID, in: content)
            try await PinnedPageTests.until({ content.focusedPane === pane })
            try await PinnedPageTests.until({ content.focus.state.topology.pane(right.paneKey) != nil })
            // The link's tab: expected now, listed by a pane change that is still queued.
            let link = FocusTopology.Tab(id: "tab_clicked_link", kind: .browser)
            content.focus.expect(.tab(link.id), generation: content.beginFocusIntent())
            var queued = content.focus.state.topology
            let column = try #require(queued.panes.firstIndex { $0.id == right.paneKey })
            queued.panes[column].tabs.append(link)
            let owner = NSObject()
            content.focus.setNeedsTopology(owner: owner) { queued }
            // The page's own ask, outside an input event and the focus model's moves.
            _ = window.makeFirstResponder(page)
            #expect(content.focus.state.pane == right.paneKey, "the page's own focus ask took the focus from the link's tab")
        }
    }

    /// An agent's open beside its lone chat docks the chat left and keeps the focus in it. That
    /// refocus is the app's, not the person's: it must not read as the person acting, or a second
    /// open in flight (Changes then Preview, two agents in one window) would skip selecting its tab.
    @Test func anAgentsOpenFromALoneChatRefocusesTheChatAsTheApp() async throws {
        try await PinnedPageTests.withApp { services, connection in
            let store = services.daemon.store
            let content = try #require(services.windows.active?.workspaceContent)
            let model = try #require(store.workspaces.first?.screens.first?.panes.first)
            let pane = try #require(services.paneController(for: model))
            let terminal = try #require(model.tabs.first?.surface)
            let record = AgentSessionRef(host: AgentSessionRef.host(installID: "cn-linkfocus-test"), hostName: "This Mac",
                                         session: "chat-lone", harness: "claude")
            let chat = try await connection.request(NewConversationTabRequest(agentSession: record, pane: model.handle))
            try await PinnedPageTests.until({ pane.pane.tabs.contains { $0.surface == chat.surface } })
            try await connection.closeTab(terminal)
            try await PinnedPageTests.until({ pane.pane.tabs.count == 1 && pane.pane.tabs.first?.surface == chat.surface })
            PaneHandlers.focus(pane.layoutPaneID, in: content)
            try await PinnedPageTests.until({ content.focusedPane === pane })
            let asked = content.focus.state.generation

            var invocation = ActionInvocation(target: ActionTargetRef(kind: .pane, id: pane.paneKey), origin: .cli)
            invocation.besideCaller = true
            invocation.newColumnBeside = true
            let placed = AgentBesidePlacement.placed(invocation, in: pane, then: nil)
            let agents = try await connection.newFrontendBrowserTab(url: "https://example.com/agent", engine: .webkit,
                                                                    in: model.handle, activate: false)
            placed(agents.surface)
            @MainActor func dock() -> PaneModel? { store.workspaces.flatMap(\.screens).flatMap(\.panes).first { $0.tabs.contains { $0.surface == chat.surface } } }
            try await PinnedPageTests.until({ dock().map { $0 !== model } == true && content.focusedPane?.pane === dock() },
                                            report: { "the chat did not dock with the focus: " + Self.describe(content, chat.surface.description) })
            #expect(content.focus.state.generation == asked, "the app's refocus of the chat counted as the person acting")
        }
    }

    /// The chat header's Preview (Changes and Files take the same path): a person's click, so the
    /// tab that opens in a new column right of the page takes the focus, unlike an agent's own
    /// beside_caller open, and its close gives the focus back to the page it was clicked in.
    @Test func theHeadersPreviewBesideThePageTakesTheFocusAndItsCloseGivesItBack() async throws {
        try await PinnedPageTests.withApp { services, _ in
            let store = services.daemon.store
            let content = try #require(services.windows.active?.workspaceContent)
            let model = try #require(store.workspaces.first?.screens.first?.panes.first)
            let pane = try #require(services.paneController(for: model))
            let source = try #require(model.tabs.first?.id)
            PaneHandlers.focus(pane.layoutPaneID, in: content)
            try await PinnedPageTests.until({ content.focusedPane === pane })
            let before = Set(store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs).map(\.id))

            // A closed loopback port: the page never loads, and nothing leaves the machine.
            AgentChatTabActions(tab: { source }, registry: { services.registry })
                .runBeside("openBrowser", arguments: ["url": .string("http://127.0.0.1:9/")], on: nil)
            @MainActor func opened() -> String? {
                // The daemon's tab: a person's link shows a stand-in first (PaneBrowserTabOpener.openStandIn), which it replaces.
            store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs).first { !before.contains($0.id) && !ProvisionalTab.isProvisional($0.id) }?.id
            }
            try await PinnedPageTests.until({ opened() != nil }, report: { "Preview opened no tab" })
            let tab = try #require(opened())
            try await PinnedPageTests.until({ content.focusedPane !== pane && content.focusedPane?.stripModel.selectedID?.rawValue == tab },
                                            report: { Self.describe(content, tab) })

            #expect(services.registry.perform("closeTab", invocation: ActionInvocation(origin: .user)))
            try await PinnedPageTests.until({ store.tab(id: tab) == nil }, report: { "Preview's tab did not close" })
            #expect(store.tab(id: source) != nil, "Cmd-W closed the page Preview was clicked in")
            try await PinnedPageTests.until({ content.focusedPane === pane }, report: { "after the close: " + Self.describe(content, source) })
        }
    }

    /// A file link or path chip in a chat (`link.openPath`, LinkOpener.openFile): its tab takes the focus.
    @Test func aFileLinksTabTakesTheFocus() async throws {
        try await PinnedPageTests.withApp { services, _ in
            let store = services.daemon.store
            let content = try #require(services.windows.active?.workspaceContent)
            let model = try #require(store.workspaces.first?.screens.first?.panes.first)
            let pane = try #require(services.paneController(for: model))
            PaneHandlers.focus(pane.layoutPaneID, in: content)
            try await PinnedPageTests.until({ content.focusedPane === pane })
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("clicked-link-\(UUID().uuidString).md")
            try Data("# Notes\n".utf8).write(to: file)
            defer { try? FileManager.default.removeItem(at: file) }
            let before = Set(store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs).map(\.id))

            #expect(services.linkOpener.openFile(file, from: pane))
            // The daemon's tab, not the split's pending one it replaces.
            @MainActor func opened() -> String? {
                store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs)
                    .first { !before.contains($0.id) && !ProvisionalTab.isProvisional($0.id) }?.id
            }
            try await PinnedPageTests.until({ opened() != nil }, report: { "the file link opened no tab" })
            let tab = try #require(opened())
            try await PinnedPageTests.until({ content.focusedPane?.stripModel.selectedID?.rawValue == tab }, report: { Self.describe(content, tab) })
        }
    }

    /// A split's pane keeps its controller from the key press through the daemon's confirm: the
    /// window mounts the provisional pane in the key's turn, and the confirm swaps only its tab.
    /// So a controller taken before the confirm (by the focus, or by a test) is the one that shows
    /// the confirmed pane, never a dead one the window has released and built again.
    @Test func aSplitsPaneKeepsItsControllerThroughItsConfirm() async throws {
        try await PinnedPageTests.withApp { services, _ in
            let content = try #require(services.windows.active?.workspaceContent)
            let panes = Set(content.panes.keys)
            #expect(services.registry.perform("splitRight", invocation: ActionInvocation(origin: .user)))
            let provisional = try #require(content.panes.first { !panes.contains($0.key) }?.value, "the split's pane is not shown in the key's turn")
            #expect(!provisional.pane.tabs.isEmpty && provisional.pane.tabs.allSatisfy { ProvisionalTab.isProvisional(surface: $0.surface) }, "the split confirmed before the window showed it")

            let id = provisional.layoutPaneID
            try await PinnedPageTests.until({ content.panes[id]?.pane.tabs.contains { !ProvisionalTab.isProvisional(surface: $0.surface) } == true },
                                            report: { "the split did not confirm in its pane" })
            #expect(content.panes[id] === provisional, "the window built the split's pane again on its confirm")
        }
    }

    /// Opens the link from `pane` as a click does and returns the new tab's id once the store has it.
    private static func click(_ services: AppServices, from pane: PaneController) async throws -> String {
        let store = services.daemon.store
        let before = Set(store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs).map(\.id))
        services.linkOpener.openWeb(link, from: pane, background: false)
        @MainActor func opened() -> String? {
            // The daemon's tab: a person's link shows a stand-in first (PaneBrowserTabOpener.openStandIn), which it replaces.
            store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs).first { !before.contains($0.id) && !ProvisionalTab.isProvisional($0.id) }?.id
        }
        try await PinnedPageTests.until({ opened() != nil }, report: { "the link opened no tab" })
        return try #require(opened())
    }

    /// Splits the focused pane right and gives the new pane's controller once the daemon confirmed
    /// the split. The split shows a provisional pane at once; the daemon refuses a tab aimed at it
    /// ("unknown pane") until it confirms, which swaps in its own handle and tab in the same
    /// controller (``aSplitsPaneKeepsItsControllerThroughItsConfirm``).
    private static func splitRight(_ services: AppServices, _ content: WorkspaceContentController) async throws -> PaneController {
        let panes = Set(content.panes.keys)
        #expect(services.registry.perform("splitRight", invocation: ActionInvocation(origin: .user)))
        func confirmed() -> PaneController? {
            content.panes.first { !panes.contains($0.key) && $0.value.pane.tabs.contains { !ProvisionalTab.isProvisional(surface: $0.surface) } }?.value
        }
        try await PinnedPageTests.until({ confirmed() != nil }, report: { "the split did not confirm" })
        return try #require(confirmed())
    }

    /// The page browser tab `id` shows: its live page, else the daemon's record.
    private static func shownURL(_ services: AppServices, _ id: String) -> URL? {
        services.cache.existingBrowser(id)?.tab.state.url ?? services.daemon.store.tab(id: id)?.url.flatMap(URL.init(string:))
    }

    /// The web view of the agent page `view` shows.
    private static func page(in view: NSView) -> WKWebView? {
        if let page = view as? WKWebView, sequence(first: page.superview, next: { $0?.superview }).contains(where: { $0 is AgentPaneView }) {
            return page
        }
        return view.subviews.lazy.compactMap { page(in: $0) }.first
    }

    private static func describe(_ content: WorkspaceContentController, _ tab: String) -> String {
        let focused = content.focusedPane
        let panes = content.panes.values.map { pane in
            "\(pane.layoutPaneID)\(pane === focused ? " (focused)" : ""): \(pane.stripModel.selectedID?.rawValue ?? "none") of \(pane.pane.tabs.map(\.id))"
        }
        return "focused pane \(String(describing: focused?.layoutPaneID)) selects \(String(describing: focused?.stripModel.selectedID?.rawValue)), wanted \(tab); "
            + panes.sorted().joined(separator: "; ")
    }
}
