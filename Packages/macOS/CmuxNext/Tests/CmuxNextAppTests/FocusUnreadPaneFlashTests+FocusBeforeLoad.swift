import AppKit
@testable import CmuxNextApp
import CmuxNextBridge
@testable import CmuxNextLayout
import Testing

/// https://github.com/manaflow-ai/cmux/issues/46908, the race: the ring must blink out the moment a
/// ringing agent chat pane is focused, not once its chat has loaded. While the chat loads its Chromium
/// page window already has the keys but is not yet the cmux window's child, and the cmux window is no
/// longer main (AppKit gave main to the page window). The pane is the one the person looks at all the same.
extension FocusUnreadPaneFlashTests {
    @Test func focusingAChatWhosePageWindowIsNotAttachedYetClearsTheRingAtOnce() async throws {
        let fixture = try await Self.open(agentChat: true)
        let page = try WindowHoldsKeyboardTests.pageWindowClass().init(contentRect: CGRect(x: 300, y: 300, width: 200, height: 200), styleMask: [.borderless], backing: .buffered, defer: true)
        page.isReleasedWhenClosed = false
        defer {
            fixture.services.keyWindowSource = { nil }
            page.close()
            fixture.controller.teardown()
            fixture.window.close()
        }
        // As in the app: the cmux window is not main while its loading chat's page window has the keys.
        fixture.window.orderOut(nil)
        #expect(!fixture.window.isMainWindow, "the fixture window is still main")
        #expect(fixture.services.windows.active === fixture.controller, "the fixture window is not the active cmux window")
        let pane = LayoutPaneID(fixture.unread.id)
        fixture.services.keyWindowSource = { page }
        fixture.controller.focus.send(.windowKey(false))
        try await PinnedPageTests.until({ !fixture.controller.focus.state.windowKey })
        fixture.content.layoutModel.focus(pane, source: .keyboard)
        try await PinnedPageTests.until({ fixture.controller.focus.state.pane == fixture.unread.id })
        // No attach: the page is still loading.
        #expect(page.parent == nil)
        try await PinnedPageTests.until({ fixture.content.layoutModel.attention[pane] == nil },
                                        report: { "focusing the chat left its ring until its page window was attached" })
        #expect(fixture.unread.tabs.first?.showsUnread == false, "focusing the chat left its blue dot")
        #expect(fixture.content.layoutModel.attentionReadByEntry.contains(pane), "the ring went without the dismiss flash")
    }
}
