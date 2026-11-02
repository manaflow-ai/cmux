import AppKit
import CmuxNextPages
import Testing

/// The New Tab spare's parking keeps its page out of sight, the mouse and the accessibility tree,
/// far outside the window content, while a Chromium page in it still draws before Cmd-T adopts it.
@MainActor
struct PageOffscreenParkingTests {
    @Test func theParkingIsTransparentInertAndOffTheContent() {
        let parking = PageOffscreenParking(frame: .zero)
        #expect(parking.alphaValue == 0)
        #expect(parking.hitTest(.zero) == nil)
        #expect(!parking.acceptsFirstResponder)
        #expect(parking.isAccessibilityHidden())
        let bounds = NSRect(x: 0, y: 0, width: 800, height: 600)
        let frame = PageOffscreenParking.frame(in: bounds, size: NSSize(width: 400, height: 300))
        #expect(!frame.intersects(bounds))
        #expect(frame.size == NSSize(width: 400, height: 300))
        #expect(PageOffscreenParking.frame(in: bounds, size: nil).size == bounds.size)
    }
}
