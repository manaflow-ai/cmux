import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextTabs
import Foundation
import Testing

/// Leo 2026-10-21: "there's some bullshit where when i close a tab in the browser then it
/// refocuses immediately back to the agent pane and so when im trying to close all stuff in the
/// brwoser area tabs... it hopss over to my main pane and closes that". The browser tabs were
/// opened from the agent chat (a clicked link, the header's Preview), and each one's close gave
/// the focus back to the chat (#22990), so the next Cmd-W closed the chat.
///
/// The rule: a closed tab's pane keeps the focus while it has tabs, on the neighbour the close
/// selects (the next tab, else the previous). Only the close of a pane's last tab moves the focus
/// to another pane, and the quick presses after that one close nothing there
/// (``EmptiedPaneCloseRun``). Runs the app's Close Tab against a same-tree cmux-tui daemon.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct CloseTabKeepsPaneTests {
    /// An agent chat on the left; on the right a pane of three browser tabs opened from the chat.
    /// Cmd-W three times, then once more at once: the focus stays in the browser pane while it
    /// has tabs, each close selects the neighbour, and the chat survives all four presses.
    @Test func cmdWClosesTheBrowserPanesTabsAndNeverTheAgentChat() async throws {
        try await PinnedPageTests.withApp { services, connection in
            // The presses wait on the daemon between them; a loaded host must not end the run early.
            services.quickPressWindow = { 60 }
            let store = services.daemon.store
            let content = try #require(services.windows.active?.workspaceContent)
            let model = try #require(store.workspaces.first?.screens.first?.panes.first)
            let agentPane = try #require(services.paneController(for: model))
            let browserPane = try await Self.splitRight(services, content)
            let terminal = try #require(browserPane.pane.tabs.first?.surface)

            // The agent chat, selected in the left pane.
            let record = AgentSessionRef(host: AgentSessionRef.host(installID: "cn-close-keeps-pane"), hostName: "This Mac",
                                         session: "chat-close-keeps-pane", harness: "claude")
            let chat = try await connection.request(NewConversationTabRequest(agentSession: record, pane: model.handle))
            try await PinnedPageTests.until({ store.tab(surface: chat.surface).map { agentPane.orderedIDs.map(\.rawValue).contains($0.id) } == true })
            let chatID = try #require(store.tab(surface: chat.surface)).id
            agentPane.select(TabID(chatID))

            // Three browser tabs alone in the right pane, each opened from the chat as a click opens
            // one (LinkOpener.openWeb, AgentBesidePlacement.focus): its close would give the focus back.
            var surfaces: [SurfaceID] = []
            for index in 0..<3 {
                let tab = try await connection.newFrontendBrowserTab(url: "https://example.com/\(index)", engine: .webkit,
                                                                     in: browserPane.pane.handle, activate: false)
                surfaces.append(tab.surface)
            }
            try await connection.closeTab(terminal)
            try await PinnedPageTests.until({ surfaces.allSatisfy { store.tab(surface: $0) != nil } })
            var ids: [String] = []
            for surface in surfaces { ids.append(try #require(store.tab(surface: surface)).id) }
            try await PinnedPageTests.until({ browserPane.orderedIDs.map(\.rawValue) == ids },
                                            report: { "the browser pane holds \(browserPane.orderedIDs.map(\.rawValue)), wanted \(ids)" })
            for surface in surfaces { services.linkOpener.returnFocus(of: surface, to: agentPane.layoutPaneID, in: content) }

            // Start on the middle tab: the first close has a tab on its right, the second only on its left.
            browserPane.select(TabID(ids[1]))
            PaneHandlers.focus(browserPane.layoutPaneID, in: content)
            try await PinnedPageTests.until({ content.focusedPane === browserPane && browserPane.stripModel.selectedID?.rawValue == ids[1] })

            // Each close: the tab goes, the pane keeps the focus, its neighbour is selected.
            for (closed, next) in [(ids[1], ids[2]), (ids[2], ids[0])] {
                #expect(services.registry.perform("closeTab", invocation: ActionInvocation(origin: .user)))
                try await PinnedPageTests.until({ store.tab(id: closed) == nil && browserPane.stripModel.selectedID?.rawValue == next },
                                                report: { "closing \(closed): " + Self.describe(content, next) })
                #expect(content.focusedPane === browserPane, "closing \(closed) moved the focus: \(Self.describe(content, next))")
                #expect(store.tab(id: chatID) != nil, "Cmd-W closed the agent chat")
            }

            // The last tab: the pane closes with it, the focus goes back to the chat it was opened from.
            #expect(services.registry.perform("closeTab", invocation: ActionInvocation(origin: .user)))
            try await PinnedPageTests.until({ store.tab(id: ids[0]) == nil && content.focusedPane === agentPane },
                                            report: { "closing the last tab: " + Self.describe(content, chatID) })
            // A quick press after it is part of the same burst: it closes nothing in the chat's pane.
            _ = services.registry.perform("closeTab", invocation: ActionInvocation(origin: .user))
            try await Task.sleep(for: .milliseconds(500))
            #expect(store.tab(id: chatID) != nil, "the press after the pane closed closed the agent chat")
            #expect(agentPane.orderedIDs.map(\.rawValue).contains(chatID), "the agent chat left its pane")
        }
    }

    /// Pure: the neighbour a close selects (``FocusAfterClose/tab(selected:old:surviving:shown:opener:)``):
    /// the next tab, else the previous; nil once no tab is left.
    @Test func aClosedTabsNeighbourIsTheNextElseThePrevious() {
        func next(_ selected: String, _ old: [String]) -> String? {
            let surviving = old.filter { $0 != selected }
            return FocusAfterClose.tab(selected: selected, old: old, surviving: surviving, shown: Set(surviving))
        }
        #expect(next("b", ["a", "b", "c"]) == "c")
        #expect(next("c", ["a", "c"]) == "a")
        #expect(next("a", ["a"]) == nil)
    }

    /// Pure: the run that starts when a Cmd-W empties its pane (``EmptiedPaneCloseRun``).
    @Test func quickPressesAfterAPaneEmptiedCloseNothingUntilAPause() {
        var run = EmptiedPaneCloseRun()
        // A press at each time, in order: whether it closed nothing.
        func presses(_ times: [TimeInterval]) -> [Bool] { times.map { run.swallows(at: $0, window: 0.5) } }
        // No run: a press closes.
        let before = presses([10])
        #expect(before == [false])
        run.emptied(at: 10)
        // Quick presses and key repeats each extend the run; a pause ends it, and the quick press after that closes too.
        let burst = presses([10.3, 10.7, 11.1, 11.7, 11.8])
        #expect(burst == [true, true, true, false, false])
        #expect(run.last == nil)
        // A clock that went back never swallows.
        run.emptied(at: 20)
        let backwards = presses([19])
        #expect(backwards == [false])
    }

    /// Splits the focused pane right and gives the new pane's controller once the daemon confirmed it.
    private static func splitRight(_ services: AppServices, _ content: WorkspaceContentController) async throws -> PaneController {
        let panes = Set(content.panes.keys)
        #expect(services.registry.perform("splitRight", invocation: ActionInvocation(origin: .user)))
        func confirmed() -> PaneController? {
            content.panes.first { !panes.contains($0.key) && $0.value.pane.tabs.contains { !ProvisionalTab.isProvisional(surface: $0.surface) } }?.value
        }
        try await PinnedPageTests.until({ confirmed() != nil }, report: { "the split did not confirm" })
        return try #require(confirmed())
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
