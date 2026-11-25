import AppKit
@testable import CmuxNextApp
import CmuxNextBridge
@testable import CmuxNextLayout
import Testing

/// https://github.com/manaflow-ai/cmux/issues/46908: a pane whose agent chat has not loaded yet
/// (its page is not up; in a test it never is) is focused while it rings. Its ring must blink
/// out on the screen at once, not only in the layout model, and not only once the focus leaves.
extension FocusUnreadPaneFlashTests {
    @Test func focusingAnAgentChatStillLoadingBlinksItsRingOutOnScreen() async throws {
        let fixture = try await Self.open(agentChat: true)
        defer {
            fixture.controller.teardown()
            fixture.window.close()
        }
        let pane = LayoutPaneID(fixture.unread.id)
        let host = try #require(Self.chatHost(of: pane, in: fixture.content.layoutView), "the chat pane has no host view")
        try await PinnedPageTests.until({ host.chromeInputs?.attention != nil }, report: { "the loading chat's pane never drew its ring" })
        fixture.content.layoutModel.focus(pane, source: .keyboard)
        try await PinnedPageTests.until({ fixture.controller.focus.state.pane == fixture.unread.id })
        try await PinnedPageTests.until({ fixture.content.layoutModel.attention[pane] == nil },
                                        report: { "focusing the loading chat left its ring in the model" })
        #expect(fixture.unread.tabs.first?.showsUnread == false, "focusing the loading chat left its blue dot")
        // What the person sees: the pane's own chrome, while the focus stays on it.
        try await PinnedPageTests.until({ host.chromeInputs?.attention == nil },
                                        report: { "the loading chat's pane kept drawing its ring while focused (\(String(describing: fixture.controller.focus.state.resolved)))" })
        #expect(host.chromeInputs?.readByEntry == true, "the loading chat's ring went without the dismiss flash")
        #expect(fixture.controller.focus.state.pane == fixture.unread.id, "the focus left the chat pane")
    }

    private static func chatHost(of pane: LayoutPaneID, in view: NSView) -> PaneHostView? {
        if let host = view as? PaneHostView, host.pane == pane { return host }
        for child in view.subviews { if let found = chatHost(of: pane, in: child) { return found } }
        return nil
    }
}
