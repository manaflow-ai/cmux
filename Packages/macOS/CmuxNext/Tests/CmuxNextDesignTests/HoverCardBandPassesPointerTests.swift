import AppKit
@testable import CmuxNextDesign
import CmuxNextTestSupport
import Testing

/// Lawrence 2026-11-09, on the "Updated to Nightly" card with its changes open beside it: the x
/// "can't be hovered". The open hover card's window is the card plus a clear band (the shadow and
/// the slide's room) that reaches over the card it opened beside, where the x sits. Hover asked
/// which window is under the pointer, got the band, decided the pointer had left, and faded the x
/// out under it. The band passes the pointer to the window below; only the card itself is topmost.
@MainActor @Suite(.serialized, .closesItsWindows) struct HoverCardBandPassesPointerTests {
    private static func parent() -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 700, height: 500), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        return window
    }

    private static func body() -> NSView {
        let body = NSView()
        body.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([body.widthAnchor.constraint(equalToConstant: 240), body.heightAnchor.constraint(equalToConstant: 120)])
        return body
    }

    @Test func theBandOverTheAnchorPassesThePointerAndTheCardKeepsIt() throws {
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }
        let parent = Self.parent()
        let panel = HoverCardPanel()
        defer {
            panel.closeAfterTest()
            parent.close()
        }
        // A sidebar card at the window's foot, as the Updated card; its x is near its right end.
        let anchor = CGRect(x: parent.frame.minX + 8, y: parent.frame.minY + 40, width: 220, height: 48)
        panel.present(body: Self.body(), anchor: anchor, placement: .beside, parent: parent, themeAnchor: nil,
                      sliding: false, interactive: true, applyTheme: {})
        let x = CGPoint(x: anchor.maxX - 12, y: anchor.midY)
        #expect(panel.frame.contains(x), "the test needs the band over the anchor's x: \(panel.frame) vs \(x)")
        let passing = try #require(panel as? any PointerPassThroughWindow, "the hover card does not pass the pointer anywhere")
        #expect(passing.passesPointer(atScreen: x), "the band over the card's x keeps the pointer")
        #expect(!passing.passesPointer(atScreen: CGPoint(x: panel.cardFrame.midX, y: panel.cardFrame.midY)), "the card itself passes the pointer")
    }

    @Test func theTopmostWindowLooksThroughWindowsThatPassThePointer() {
        // Front to back: the hover card (7) over the main window (3).
        let below = [0: 7, 7: 3, 3: 0]
        #expect(PointerHover.topmostWindow(passes: { $0 == 7 }, below: { below[$0] ?? 0 }) == 3)
        #expect(PointerHover.topmostWindow(passes: { _ in false }, below: { below[$0] ?? 0 }) == 7)
    }
}
