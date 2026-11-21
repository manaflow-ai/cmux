import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextBridge
@testable import CmuxNextDaemon
import CmuxNextFocus
import CmuxNextTabs
import CmuxNextTerminal
import Foundation
import Testing

/// Lawrence 2026-11-10 ("there are multiple steps"): the focus moves to an agent chat tab or an internal page tab this
/// window never showed (its view comes on a later frame) while a terminal in another pane has the keyboard. Keys typed
/// then are for that tab: they wait for its view, and never go into the terminal that had the keyboard. Before the
/// fix, the focus effect for such a tab did nothing and no key hold began, so that terminal kept the keyboard and a
/// plain line typed at once ran in its shell. The same fault for a browser tab is ``ColdBrowserFocusKeysTests``.
///
/// The test spends the frame's surface budget, selects and focuses the cold tab in the same turn (so its view is not
/// made in that turn), and types a plain line at once through the app's key path (the key router, then the window).
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct ColdAgentAndPageFocusKeysTests {
    /// A pane that spends the frame's one new surface (``ContentPresentationScheduler``).
    @MainActor private final class BudgetSpender: PresentablePane {
        var selectedContentIsAlive: Bool { false }
        var isFocusedInWorkspace: Bool { false }
        func showSelected() {}
        func showWhileWaiting() {}
    }

    enum Cold: String, CaseIterable, Sendable { case agent, page }

    @Test(arguments: Cold.allCases)
    func plainKeysTypedAsTheFocusMovesToAColdTabNeverReachTheTerminalThatHadTheKeyboard(_ cold: Cold) async throws {
        try await PinnedPageTests.withApp(heldKeyReplay: { event, window, router in
            if !router.interceptKeyDown(event, in: window) { window.sendEvent(event) }
        }) { services, connection in
            try await PinnedPageTests.until({ !services.windows.registry.isLaunching }, within: .seconds(60))
            let controller = try #require(services.windows.active)
            let window = try #require(controller.window)
            window.setFrame(NSRect(x: 0, y: 0, width: 1100, height: 760), display: true)
            let router = services.keyRouter, coordinator = router.creationInputCoordinator
            @MainActor func describe() -> String {
                "panes \(controller.workspaceContent?.panes.values.map { "\($0.paneKey): \($0.currentTabKey ?? "-")" } ?? [])"
                    + " focus \(controller.focus.state.resolved) first responder \(String(describing: window.firstResponder))"
            }

            // A workspace with two terminals side by side; the left one gets the keyboard.
            let id = try #require(await services.windows.createWorkspace(into: controller.state.id))
            @MainActor func terminals() -> [(pane: PaneController, tab: String, surface: SurfaceID)] {
                guard controller.workspaceContent?.workspace.id == id, let content = controller.workspaceContent else { return [] }
                return content.panes.values.compactMap { pane in
                    guard pane.pane.handle.rawValue < ProvisionalPane.firstHandle, let tab = pane.currentTabKey, case .terminal? = pane.currentContent,
                          let model = pane.pane.tabs.first(where: { $0.id == tab && $0.kind == .pty && !ProvisionalTab.isProvisional(surface: $0.surface) })
                    else { return nil }
                    return (pane, tab, model.surface)
                }
            }
            try await PinnedPageTests.until({
                if controller.workspaceContent?.workspace.id != id { services.windows.show(workspaceID: id, in: controller.state) }
                return terminals().count == 1
            }, report: { "waiting for the workspace's terminal: \(describe())" })
            var split = ActionInvocation(origin: .user)
            split.opensTerminal = true
            #expect(services.registry.perform("splitRight", invocation: split))
            try await PinnedPageTests.until({ terminals().count == 2 }, report: { "waiting for the split's terminal: \(describe())" })
            let content = try #require(controller.workspaceContent)
            let ordered = terminals().sorted { $0.pane.view.frame.minX < $1.pane.view.frame.minX }
            let left = ordered[0].pane, leftTab = ordered[0].tab, leftSurface = ordered[0].surface, right = ordered[1].pane
            let leftEntry: TerminalEntry = try #require({
                guard case .terminal(let entry)? = left.currentContent else { return nil }
                return entry
            }(), "the left terminal has no live entry")
            PaneHandlers.focus(left.layoutPaneID, in: content)
            try await PinnedPageTests.until({ controller.focus.state.resolved == .terminal(pane: left.paneKey, tab: leftTab)
                    && (window.firstResponder as? NSView)?.isDescendant(of: left.view) == true },
                report: { "waiting for the keyboard on the left terminal: \(describe())" })
            try await connection.send(leftSurface, text: "echo ready$((3*3))\r")
            let ready = try? await connection.request(WaitForTextRequest(surface: leftSurface, pattern: "ready9", timeoutMs: 20_000), timeout: .seconds(25))
            try #require(ready?.matched == true, "the left shell never answered")

            // A tab in the right pane, not selected: this window never made its view.
            let tab: String
            switch cold {
            case .agent:
                if services.agentTabs.localHost == nil { services.agentTabs.localHost = "install:cold-agent-keys" }
                tab = try await services.agentTabs.open(in: right.pane.handle, of: right.daemon).value().key
            case .page:
                tab = services.pages.open(.changelog, in: right.paneKey, of: services.daemon.store)
            }
            try await PinnedPageTests.until({ right.stripModel.tab(StripTabID(tab)) != nil && right.orderedIDs.contains(StripTabID(tab)) },
                                            report: { "the cold tab is not in the strip: \(right.orderedIDs)" })
            try #require(right.stripModel.selectedID?.rawValue != tab, "the cold tab was selected: its view may already be made")
            try await PinnedPageTests.until({ !coordinator.isHolding(in: window) }, report: { "waiting for the split's hold to end" })

            // In one turn: the frame's surface budget is spent, the tab is selected and focused, and a line is typed.
            let nonce = String(UInt32.random(in: 100_000...999_999))
            _ = services.presentation.showNow(BudgetSpender()) // false: another pane spent it already
            right.select(StripTabID(tab))
            PaneHandlers.focus(right.layoutPaneID, in: content)
            let wanted: FocusState.Resolved = cold == .agent ? .agentPage(pane: right.paneKey, tab: tab) : .page(pane: right.paneKey, tab: tab)
            try #require(controller.focus.currentState().resolved == wanted, "the focus is not the cold tab: \(controller.focus.state.resolved)")
            try #require(right.currentTabKey != tab, "the cold tab's view was made in the focus turn: the test types too late")
            var paths: [String] = []
            for character in "echo c5x\(nonce)\r" {
                let text = String(character)
                let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                          context: nil, characters: text, charactersIgnoringModifiers: text,
                                                          isARepeat: false, keyCode: text == "\r" ? 36 : 0))
                if router.interceptKeyDown(event, in: window) {
                    paths.append("\(text.debugDescription): held")
                } else {
                    paths.append("\(text.debugDescription): to \(window.firstResponder.map { String(describing: type(of: $0)) } ?? "none")")
                    window.sendEvent(event)
                }
            }
            #expect(paths.first?.hasSuffix("held") == true, "the first key typed for the cold tab was not held for it: \(paths)")
            #expect(!paths.contains { $0.contains("TerminalSurfaceView") }, "keys typed for the cold tab went to a terminal view: \(paths)")

            // The tab's view comes; the keys went to it (or wait for it), never to the left terminal's shell.
            try await PinnedPageTests.until({ right.currentTabKey == tab }, report: { "the cold tab's view never came: \(describe())" })
            // The same ordered terminal IO as the key path: the barrier's echo proves the PTY processed any key bytes
            // sent before it (as ColdBrowserFocusKeysTests).
            let barrier = "c5x-barrier-\(nonce)"
            await leftEntry.io.write(Data("echo \(barrier)\r".utf8))
            let barrierSeen = try? await connection.request(
                WaitForTextRequest(surface: leftSurface, pattern: barrier, timeoutMs: 20_000), timeout: .seconds(25))
            let screen = (try? await connection.request(ReadScreenRequest(surface: leftSurface), timeout: .seconds(5)))?.text ?? "unreadable"
            #expect(barrierSeen?.matched == true, "the left shell never reached the ordered barrier: \(screen)")
            #expect(!screen.contains("c5x\(nonce)"), "keys typed for the cold tab reached the terminal that had the keyboard: \(screen)\nkey paths: \(paths)")
        }
    }
}
