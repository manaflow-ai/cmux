import AppKit
@testable import CmuxNextApp
import CmuxNextBridge
@testable import CmuxNextLayout
import Testing

/// https://github.com/manaflow-ai/cmux/issues/46908: clicking a ringing agent chat pane blinks its
/// ring out at once, every time, driven by the pane focus itself. The chat may still be loading: its
/// Chromium page window has the keys but is not the cmux window's child yet, and AppKit made it main,
/// so the viewed-tab rules do not count the pane as looked at until the page is attached. The blink
/// and the read must not wait for that, nor for any later pass over the attention marks.
extension FocusUnreadPaneFlashTests {
    @Test func focusingARingingChatBlinksItsRingOutInTheSamePassBeforeItsPageLoads() async throws {
        let fixture = try await Self.open(agentChat: true)
        let page = try WindowHoldsKeyboardTests.pageWindowClass().init(contentRect: CGRect(x: 300, y: 300, width: 200, height: 200), styleMask: [.borderless], backing: .buffered, defer: true)
        page.isReleasedWhenClosed = false
        defer {
            fixture.services.keyWindowSource = { nil }
            page.close()
            fixture.controller.teardown()
            fixture.window.close()
        }
        // As in the app while the chat loads: its page window has the keys, unattached, and the cmux window is not main.
        fixture.window.orderOut(nil)
        #expect(!fixture.window.isMainWindow, "the fixture window is still main")
        #expect(fixture.services.windows.active === fixture.controller, "the fixture window is not the window worked in")
        fixture.services.keyWindowSource = { page }
        fixture.controller.focus.send(.windowKey(false))
        try await PinnedPageTests.until({ !fixture.controller.focus.state.windowKey })
        let pane = LayoutPaneID(fixture.unread.id)
        let model = fixture.content.layoutModel
        #expect(model.attention[pane] != nil, "the chat pane does not ring before the focus")

        model.focus(pane, source: .pointer)
        // The same pass: no await between the focus and these reads, so no other pass can decide the ring.
        #expect(model.attention[pane] == nil, "focusing the ringing chat left its ring until a later pass")
        #expect(model.attentionReadByEntry.contains(pane), "the ring went without the dismiss blink")
        #expect(page.parent == nil, "the page window was attached")

        // The read is the focus's too: the blue dot goes with no page attach and no key change.
        try await PinnedPageTests.until({ fixture.unread.tabs.first?.showsUnread == false },
                                        report: { "focusing the chat left its blue dot until its page loads" })
        // Later passes over the marks (the read coming back) keep the blink: the chrome draws the ring going by entry.
        let host = try #require(Self.entryHost(of: pane, in: fixture.content.layoutView), "the chat pane has no host view")
        try await PinnedPageTests.until({ host.chromeInputs?.attention == nil }, report: { "the pane's chrome kept the ring" })
        #expect(host.chromeInputs?.readByEntry == true, "the pane's chrome dropped the ring without the dismiss blink")
        #expect(model.attention[pane] == nil, "the ring came back after the read")
    }

    /// The screenshot case: the ringing chat pane already has the focus (it was focused while cmux was in
    /// the back, and its page window, not attached yet, has the keys), so no focus move comes. A click
    /// into it must blink the ring out in the same pass, not leave it standing.
    @Test func clickingAFocusedRingingChatBlinksItsRingOutInTheSamePass() async throws {
        let fixture = try await Self.open(agentChat: true)
        let page = try WindowHoldsKeyboardTests.pageWindowClass().init(contentRect: CGRect(x: 300, y: 300, width: 200, height: 200), styleMask: [.borderless], backing: .buffered, defer: true)
        page.isReleasedWhenClosed = false
        defer {
            fixture.services.keyWindowSource = { nil }
            fixture.services.appActiveSource = { true }
            page.close()
            fixture.controller.teardown()
            fixture.window.close()
        }
        let pane = LayoutPaneID(fixture.unread.id)
        let model = fixture.content.layoutModel
        fixture.services.appActiveSource = { false }
        model.focus(pane, source: .pointer)
        try await PinnedPageTests.until({ fixture.controller.focus.state.pane == fixture.unread.id })
        fixture.window.orderOut(nil)
        fixture.services.keyWindowSource = { page }
        fixture.controller.focus.send(.windowKey(false))
        try await PinnedPageTests.until({ !fixture.controller.focus.state.windowKey })
        fixture.services.appActiveSource = { true }
        #expect(model.attention[pane] != nil, "the focused chat pane does not ring before the click")
        let host = try #require(Self.entryHost(of: pane, in: fixture.content.layoutView), "the chat pane has no host view")
        fixture.content.contentView.layoutSubtreeIfNeeded()
        let point = host.convert(NSPoint(x: host.bounds.midX, y: host.bounds.midY), to: nil)

        fixture.services.notifications.noteMouseDown(in: fixture.window, at: point, synthetic: true)
        #expect(model.attention[pane] == nil, "clicking the focused ringing chat left its ring")
        #expect(model.attentionReadByEntry.contains(pane), "the click took the ring without the dismiss blink")
        try await PinnedPageTests.until({ fixture.unread.tabs.first?.showsUnread == false },
                                        report: { "clicking the chat left its blue dot" })
        try await PinnedPageTests.until({ host.chromeInputs?.attention == nil }, report: { "the pane's chrome kept the ring" })
        #expect(host.chromeInputs?.readByEntry == true, "the pane's chrome dropped the ring without the dismiss blink")
    }

    private static func entryHost(of pane: LayoutPaneID, in view: NSView) -> PaneHostView? {
        if let host = view as? PaneHostView, host.pane == pane { return host }
        for child in view.subviews { if let found = entryHost(of: pane, in: child) { return found } }
        return nil
    }
}
