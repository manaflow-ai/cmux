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

    @Test func hidesAfterItsLifetime() async {
        let window = window()
        defer { window.close() }
        let clock = ManualClock()
        let hud = RefusalHUD(clock: clock)
        hud.show("refused", in: window)
        await clock.sleepers()
        #expect(hud.message == "refused")
        // Read before the main-actor hide has run, as the old wall-clock poll
        // did when a loaded runner held the main actor past its deadline.
        clock.advance(by: hud.lifetime)
        #expect(hud.message == nil)
    }
}
