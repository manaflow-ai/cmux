import AppKit
@testable import CmuxNextApp
import CmuxNextBridge
@testable import CmuxNextLayout
import Testing

/// https://github.com/manaflow-ai/cmux/issues/46908: a ringing agent chat pane is focused before
/// its chat has loaded. Its Chromium page window takes the keys first and becomes the cmux window's
/// child only later, when the page is attached; the cmux window is no longer main by then. Until
/// that attach the window does not hold the keyboard, so the pane is not viewed and keeps its ring,
/// which is right; but the attach came with no key change, so nothing looked again and the ring
/// stayed until the focus went to another pane.
extension FocusUnreadPaneFlashTests {
    @Test func aChatPageWindowAttachedAfterItTookTheKeysClearsTheRing() async throws {
        let fixture = try await Self.open(agentChat: true)
        let page = try WindowHoldsKeyboardTests.pageWindowClass().init(contentRect: CGRect(x: 300, y: 300, width: 200, height: 200), styleMask: [.borderless], backing: .buffered, defer: true)
        page.isReleasedWhenClosed = false
        defer {
            fixture.services.keyWindowSource = { nil }
            fixture.window.removeChildWindow(page)
            page.close()
            fixture.controller.teardown()
            fixture.window.close()
        }
        let pane = LayoutPaneID(fixture.unread.id)
        // The page window, not yet a child, takes the keys as the chat pane is focused.
        fixture.services.keyWindowSource = { page }
        fixture.controller.focus.send(.windowKey(false))
        try await PinnedPageTests.until({ !fixture.controller.focus.state.windowKey })
        fixture.content.layoutModel.focus(pane, source: .keyboard)
        try await PinnedPageTests.until({ fixture.controller.focus.state.pane == fixture.unread.id })
        #expect(fixture.window is ShellWindow, "the fixture's window is not the app's main window class")
        // The focus itself blinked the ring out and read it (cmux#46908, `+FocusEntry`); the attach must still make
        // the viewed-tab rules look again, for a tab that came into view with no focus move.
        let revision = fixture.services.notifications.viewedRevision
        // The page loads and is attached: the cmux window holds the keyboard through it now.
        fixture.window.addChildWindow(page, ordered: .above)
        #expect(fixture.services.notifications.viewedRevision != revision,
                "attaching the chat's page window did not make the viewed-tab rules look again: its ring stays until the focus moves")
        try await PinnedPageTests.until({ fixture.content.layoutModel.attention[pane] == nil },
                                        report: { "the ring stayed after the chat's page window was attached, while its pane kept the focus" })
        #expect(fixture.unread.tabs.first?.showsUnread == false, "the chat kept its blue dot")
        #expect(fixture.content.layoutModel.attentionReadByEntry.contains(pane), "the ring went without the dismiss flash")
    }
}
