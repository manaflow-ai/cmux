import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextFocus
import Testing

/// Lawrence 2026-10-29 (felt 1f): "i do cmd shift l and it opens a browser tab, but then i start typing, and
/// nothing is focused". The new tab (a stand-in the daemon's tab replaces) showed in the key's turn, but the
/// focus on its address bar was asked for only in the daemon's reply: until then the model targeted the stand-in's
/// page (or the old terminal), and keys typed after the creation hold (2 s) went there, not into the address bar.
/// Focus is part of the action's own turn (plans/cmux-next/focus-invariant.md, zero-latency.md): the new tab's
/// address bar has the keys, or is the focus the model waits for, before the action's turn ends.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct NewBrowserTabFocusTests {
    @Test func newBrowserTabPutsTheKeysOnItsAddressBarInTheKeysTurn() async throws {
        try await PinnedPageTests.withApp { services, _ in
            let content = try #require(services.windows.active?.workspaceContent)
            let pane = try #require(content.focusedPane)
            try await PinnedPageTests.until({ content.focus.state.resolved.kind == "terminal" },
                                            report: { "the first terminal never had the keys: \(content.focus.state.resolved)" })
            let before = Set(pane.stripModel.orderedTabs.map(\.id.rawValue))

            // Cmd-Shift-L, as the key router runs it: a person's openBrowser (WebKit: no Chromium in tests).
            #expect(services.registry.perform("openBrowser.webkit", invocation: ActionInvocation(origin: .user)))

            // Still in the key's turn, before any daemon reply.
            let selected = try #require(content.focusedPane?.stripModel.selectedID?.rawValue, "no tab selected after the open")
            #expect(!before.contains(selected), "the new tab is not selected in the key's turn")
            let state = content.focus.state
            let onBar: Bool = if case .addressBar(_, let tab) = state.resolved { tab == selected } else { false }
            let waitsForBar = state.expectation?.target == .addressBar
            #expect(onBar || waitsForBar,
                    "in the key's turn the keys go to \(state.resolved) and nothing waits for the new tab's address bar (expectation \(String(describing: state.expectation)))")

            // And it stays there once the daemon's tab replaced the stand-in.
            try await PinnedPageTests.until({
                if case .addressBar = content.focus.state.resolved { content.focus.state.expectation == nil } else { false }
            }, report: { "the address bar never had the keys: \(content.focus.state.resolved)" })
        }
    }
}
