import AppKit
@testable import CmuxNextDesign
import CmuxNextTestSupport
import Testing

/// A card that waits clear (the browser's cookie import card) keeps its own opacity when the host
/// presents it. The host set it to 1 and ordered its panel in before the caller set it back, so
/// the card showed one frame at full opacity first (CMUX-309).
@MainActor @Suite(.closesItsWindows, .serialized) struct OverlayKeepsContentAlphaTests {
    /// Every alpha the host gives it, in order.
    private final class AlphaRecorder: NSView {
        var given: [CGFloat] = []
        override var alphaValue: CGFloat {
            get { super.alphaValue }
            set { given.append(newValue); super.alphaValue = newValue }
        }
    }

    private static func window() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: 400, height: 300), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        return window
    }

    private static func attached(keepsAlpha: Bool) -> OverlayOptions {
        let clip = NSRect(x: 0, y: 0, width: 200, height: 150)
        var options = OverlayOptions(kind: .attached, anchor: NSRect(origin: clip.origin, size: .zero), layer: .pane(clip: clip))
        options.keepsContentAlpha = keepsAlpha
        return options
    }

    @Test func aClearCardIsNeverShownAtFullOpacity() {
        let window = Self.window()
        defer { window.closeWithOverlayHost() }
        let card = AlphaRecorder(frame: NSRect(x: 0, y: 0, width: 40, height: 20))
        card.alphaValue = 0
        card.given = []

        let handle = WindowOverlayHost.host(for: window).present(card, options: Self.attached(keepsAlpha: true))
        defer { handle.dismiss() }

        #expect(!card.given.contains(1), "the host set the waiting card to full opacity: \(card.given)")
        #expect(card.alphaValue == 0)
    }

    @Test func anOverlayPresentedAgainWhileFadingOutShowsAtFullOpacity() {
        let window = Self.window()
        defer { window.closeWithOverlayHost() }
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 40, height: 20))
        view.alphaValue = 0.3

        let handle = WindowOverlayHost.host(for: window).present(view, options: Self.attached(keepsAlpha: false))
        defer { handle.dismiss() }

        #expect(view.alphaValue == 1)
    }
}
