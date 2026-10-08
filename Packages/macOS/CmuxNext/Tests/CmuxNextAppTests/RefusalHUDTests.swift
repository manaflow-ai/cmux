import AppKit
import Testing
@testable import CmuxNextApp

/// A keyboard or menu refusal shows its reason at the bottom of the window,
/// takes no mouse, and hides after its one-shot deadline.
@MainActor
struct RefusalHUDTests {
    private func window() -> NSWindow {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView()
        return window
    }

    @Test func showsTheReasonCenteredAtTheBottom() throws {
        let window = window()
        defer { window.close() }
        let hud = RefusalHUD()
        hud.show("Not enough room to split this column", in: window)
        #expect(hud.message == "Not enough room to split this column")
        let view = try #require(window.contentView?.subviews.last as? RefusalHUDView)
        #expect(abs(view.frame.midX - 400) < 1)
        #expect(view.frame.minY < 100)
        // Seen live: the label truncated to "Not enough room to split this colu…".
        #expect(view.fitsText)
        #expect(view.hitTest(CGPoint(x: view.frame.midX, y: view.frame.midY)) == nil)
    }

    /// tab-dnd review (2026-10-04): a drop refusal shown behind a Chromium
    /// page says nothing. Pages are child windows the CEF fork orders above
    /// the parent's content, so the reason must draw in a window above
    /// them (the R84 window overlay layer). Known issue until the HUD moves
    /// into that layer (R84 core).
    @Test func theReasonDrawsAboveAChromiumPageWindow() throws {
        let window = window()
        defer { window.close() }
        let page = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
        page.isReleasedWhenClosed = false
        defer { page.close() }
        window.addChildWindow(page, ordered: .above)
        let hud = RefusalHUD()
        hud.show("Not enough room to split this column", in: window)
        withKnownIssue("R84: the HUD is in the parent content view, below Chromium page child windows") {
            let host = try #require(hud.hostWindow)
            let children = window.childWindows ?? []
            let pageIndex = try #require(children.firstIndex(of: page))
            let hostIndex = try #require(children.firstIndex(of: host), "the HUD draws in the parent, under the page")
            #expect(hostIndex > pageIndex)
        }
    }

    @Test func hidesAfterItsLifetime() async {
        let window = window()
        defer { window.close() }
        let clock = ManualClock()
        let hud = RefusalHUD(clock: clock)
        let (hidden, signal) = AsyncStream.makeStream(of: Void.self)
        hud.onHide = { signal.yield() }
        hud.show("refused", in: window)
        await clock.sleepers()
        #expect(hud.message == "refused")
        // The hide hops to the main actor after the deadline; wait for it
        // rather than reading the message straight after the advance.
        clock.advance(by: hud.lifetime)
        var iterator = hidden.makeAsyncIterator()
        #expect(await iterator.next() != nil)
        #expect(hud.message == nil)
    }
}
