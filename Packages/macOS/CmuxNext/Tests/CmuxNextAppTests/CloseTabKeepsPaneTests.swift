import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextSignposts
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
/// to another pane; a press aimed at the emptied pane (made before the frame showing the new
/// focus, or a repeat of the held key) closes nothing there (``PaneCloseAim``). Runs the app's
/// Close Tab against a same-tree cmux-tui daemon.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct CloseTabKeepsPaneTests {
    /// An agent chat on the left; on the right a pane of three browser tabs opened from the chat.
    /// Cmd-W three times: the focus stays in the browser pane while it has tabs, each close
    /// selects the neighbour, and the chat survives.
    @Test func cmdWClosesTheBrowserPanesTabsAndNeverTheAgentChat() async throws {
        try await PinnedPageTests.withApp { services, connection in
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
        }
    }

    /// Lawrence 2026-10-23: "sometimes i cmd w a few times, and some cmd w doesnt register". A Cmd-W
    /// empties the right pane, the focus moves to the left pane, and that move is drawn. The next
    /// fresh press was made while the person saw the left pane focused: it closes the left pane's
    /// tab at once, never "nothing" because it came soon after the press before.
    @Test func aFreshCmdWAfterTheFocusMoveWasDrawnClosesInThePaneNowFocused() async throws {
        try await PinnedPageTests.withApp { services, connection in
            let setup = try await Self.emptiablePanes(services, connection)
            try await Self.emptyTheRightPane(services, setup)
            try await Self.nextCommit()
            // The committed frame shows one display refresh later (16.7 ms at 60 Hz): press after that.
            try await Task.sleep(for: .milliseconds(50))
            let refusals = Self.recordRefusals(services)
            #expect(Self.press(services, .key(repeat: false, at: ProcessInfo.processInfo.systemUptime)))
            try await PinnedPageTests.until({ services.daemon.store.tab(id: setup.leftPage) == nil },
                                            report: { "the fresh press closed nothing; refusals \(refusals.reasons)" })
            #expect(refusals.reasons.isEmpty)
        }
    }

    /// Leo's case, addressed to what the person saw: a Cmd-W pressed before the frame that shows the
    /// focus in the left pane (queued behind the press that emptied the right pane), and a key repeat
    /// of the held Cmd-W that emptied it, are aimed at the right pane, which is gone. They close
    /// nothing in the left pane, and each says so (the refusal HUD), never silently.
    @Test func cmdWAimedAtTheEmptiedPaneClosesNothingElsewhereAndSaysWhy() async throws {
        try await PinnedPageTests.withApp { services, connection in
            let setup = try await Self.emptiablePanes(services, connection)
            let emptiedAt = try await Self.emptyTheRightPane(services, setup)
            let refusals = Self.recordRefusals(services)
            // Pressed 1 ms after the emptying press: before any frame could show the focus move.
            _ = Self.press(services, .key(repeat: false, at: emptiedAt + 0.001))
            try await Self.nextCommit()
            // The held Cmd-W repeats after the move was drawn: still the same press.
            _ = Self.press(services, .key(repeat: true, at: ProcessInfo.processInfo.systemUptime))
            try await Task.sleep(for: .milliseconds(300))
            #expect(services.daemon.store.tab(id: setup.leftPage) != nil, "a press aimed at the emptied pane closed the left pane's tab")
            #expect(refusals.reasons.count == 2, "each press aimed at the emptied pane says why: \(refusals.reasons)")
        }
    }

    /// Review 2 of the burst bench (2026-10-24), Lawrence's "some cmd w doesnt register": a Cmd-W
    /// empties the right pane, then Cmd-D makes a new pane and focuses it, and a quick Cmd-W closes
    /// what the person made and is looking at. Before, every Cmd-W within the quick-press window of
    /// the one before closed nothing, so a Cmd-D, Cmd-W, Cmd-W run lost its closes.
    @Test func aCmdWAfterACmdDClosesTheNewSplitEvenRightAfterAnEmptyingClose() async throws {
        try await PinnedPageTests.withApp { services, connection in
            let setup = try await Self.emptiablePanes(services, connection)
            let emptiedAt = try await Self.emptyTheRightPane(services, setup)
            let content = try #require(services.windows.active?.workspaceContent)
            try await Self.nextCommit()
            let before = Set(content.panes.keys)
            #expect(services.registry.perform("splitRight", invocation: ActionInvocation(origin: .user)))
            let made = try #require(content.panes.keys.first { !before.contains($0) }, "the split showed no pane")
            try await Self.nextCommit()
            try await Task.sleep(for: .milliseconds(50))
            // Well inside the old quick-press window of the emptying press.
            let pressedAt = ProcessInfo.processInfo.systemUptime
            #expect(pressedAt - emptiedAt < 0.5)
            #expect(Self.press(services, .key(repeat: false, at: pressedAt)))
            try await PinnedPageTests.until({ content.panes[made] == nil },
                                            report: { "the Cmd-W after the Cmd-D closed nothing: " + Self.describe(content, setup.leftPage) })
            #expect(services.daemon.store.tab(id: setup.leftPage) != nil, "the Cmd-W closed the left pane's tab instead")
        }
    }

    /// The left pane (its terminal and a selected browser tab) and the right pane (one browser tab).
    private struct EmptiablePanes {
        var left: PaneController
        var right: PaneController
        var leftPage: String
        var rightPage: String
    }

    /// One Cmd-W input: a key-down (or a repeat of one) at `at`.
    private enum Input {
        case key(repeat: Bool, at: TimeInterval)

        var event: NSEvent? {
            switch self {
            case .key(let isRepeat, let timestamp):
                NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: timestamp, windowNumber: 0,
                                 context: nil, characters: "w", charactersIgnoringModifiers: "w", isARepeat: isRepeat, keyCode: 13)
            }
        }
    }

    /// What happened since a test began to record it (refusal reasons, commits).
    @MainActor private final class Refusals {
        var reasons: [String] = []
    }

    private static func recordRefusals(_ services: AppServices) -> Refusals {
        let refusals = Refusals()
        let shown = services.registry.refusalObserver
        services.registry.refusalObserver = { reason, quiet in
            if !quiet { refusals.reasons.append(reason) }
            shown?(reason, quiet)
        }
        return refusals
    }

    /// Runs Close Tab as the person's `input` dispatches it.
    @discardableResult
    private static func press(_ services: AppServices, _ input: Input) -> Bool {
        let dispatching = services.registry.dispatchingInputEvent
        let event = input.event
        services.registry.dispatchingInputEvent = { event }
        defer { services.registry.dispatchingInputEvent = dispatching }
        return services.registry.perform("closeTab", invocation: ActionInvocation(origin: .user))
    }

    /// Returns after the next Core Animation commit of the main run loop.
    private static func nextCommit() async throws {
        let commit = Refusals()
        CommitBoundary().after { _ in commit.reasons.append("committed") }
        try await PinnedPageTests.until({ !commit.reasons.isEmpty }, report: { "no commit" })
    }

    private static func emptiablePanes(_ services: AppServices, _ connection: DaemonConnection) async throws -> EmptiablePanes {
        let store = services.daemon.store
        let content = try #require(services.windows.active?.workspaceContent)
        let model = try #require(store.workspaces.first?.screens.first?.panes.first)
        let left = try #require(services.paneController(for: model))
        let right = try await splitRight(services, content)
        let rightTerminal = try #require(right.pane.tabs.first?.surface)
        let leftTab = try await connection.newFrontendBrowserTab(url: "https://example.com/left", engine: .webkit, in: model.handle, activate: false)
        let rightTab = try await connection.newFrontendBrowserTab(url: "https://example.com/right", engine: .webkit, in: right.pane.handle, activate: false)
        try await connection.closeTab(rightTerminal)
        try await PinnedPageTests.until({ store.tab(surface: leftTab.surface) != nil && store.tab(surface: rightTab.surface) != nil })
        let leftPage = try #require(store.tab(surface: leftTab.surface)).id
        let rightPage = try #require(store.tab(surface: rightTab.surface)).id
        try await PinnedPageTests.until({ right.orderedIDs.map(\.rawValue) == [rightPage] && left.orderedIDs.map(\.rawValue).contains(leftPage) },
                                        report: { "left \(left.orderedIDs), right \(right.orderedIDs)" })
        left.select(TabID(leftPage))
        right.select(TabID(rightPage))
        PaneHandlers.focus(right.layoutPaneID, in: content)
        try await PinnedPageTests.until({ content.focusedPane === right && right.stripModel.selectedID?.rawValue == rightPage })
        return EmptiablePanes(left: left, right: right, leftPage: leftPage, rightPage: rightPage)
    }

    /// A key-down Cmd-W closes the right pane's only tab; returns the press's timestamp once the
    /// pane is gone and the focus is in the left pane.
    @discardableResult
    private static func emptyTheRightPane(_ services: AppServices, _ setup: EmptiablePanes) async throws -> TimeInterval {
        let content = try #require(services.windows.active?.workspaceContent)
        let pressedAt = ProcessInfo.processInfo.systemUptime
        #expect(press(services, .key(repeat: false, at: pressedAt)))
        try await PinnedPageTests.until({ services.daemon.store.tab(id: setup.rightPage) == nil && content.focusedPane === setup.left },
                                        report: { describe(content, setup.leftPage) })
        return pressedAt
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
