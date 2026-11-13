import AppKit
@testable import CmuxNextApp
@testable import CmuxNextLayout
import Testing

/// Agent chats (https://github.com/manaflow-ai/cmux/issues/42210): a click into a chat's Chromium
/// page reads the pane at once, but the page's focus reaches the layout later. The ring went
/// before the pane was the focused one, and the dismiss flash only played on the focused pane,
/// so the chat's ring sometimes faded. The flash's input is checked, not the animation, which
/// a test window may not run (no display link, Reduce Motion on the host).
extension FocusUnreadPaneFlashTests {
    @Test func aClickReadBeforeTheFocusMovesStillBlinksTheRingOut() async throws {
        let fixture = try await Self.open()
        defer {
            fixture.controller.teardown()
            fixture.window.close()
        }
        let pane = LayoutPaneID(fixture.unread.id)
        let tab = try #require(fixture.unread.tabs.first)
        fixture.services.notifications.interacted(.click, tab: tab)
        try await PinnedPageTests.until({ fixture.content.layoutModel.attention[pane] == nil },
                                        report: { "the click left the ring" })
        #expect(fixture.controller.focus.state.pane == fixture.quiet.id, "the fixture's focus moved")
        let host = try #require(Self.host(of: pane, in: fixture.content.layoutView), "the pane has no host view")
        try await PinnedPageTests.until({ host.chromeInputs?.attention == nil },
                                        report: { "the pane's chrome never dropped the ring" })
        #expect(host.chromeInputs?.readByEntry == true,
                "a ring read before its pane took the focus faded without the dismiss flash")
    }

    private static func host(of pane: LayoutPaneID, in view: NSView) -> PaneHostView? {
        if let host = view as? PaneHostView, host.pane == pane { return host }
        for child in view.subviews { if let found = host(of: pane, in: child) { return found } }
        return nil
    }
}
