import AppKit
@testable import CmuxNextLayout
import CmuxNextTestSupport
import Testing

/// A screen switch slides the new screen in and the old one out on the `screen` spring. A layout pass
/// of the layout root in the middle of it (a sidebar or tab strip change, anything that lays the window
/// out) must not end the slide: `LayoutRootView.layout` snapped every screen's x and y to the root's
/// bounds, so both screens jumped to the middle in that frame and the old one faded out there
/// (RESIZE VIDEOS, Lawrence 2026-11-02: every layout animation interruptible, no jump). The slide goes
/// on from where it shows; only the size follows the root at once. The test is the clock (120 Hz).
@MainActor
@Suite(.closesItsWindows)
struct ScreenSlideLayoutPassTests {
    final class Panes: LayoutPaneContentProvider {
        func makeContentView(for pane: PaneID) -> NSView { NSView() }
    }

    @Test func aLayoutPassDuringAScreenSwitchKeepsTheSlideGoing() throws {
        let model = LayoutModel(screens: [LayoutScreen(id: "a", name: "a", layout: .splits(.leaf("a-p1"))),
                                          LayoutScreen(id: "b", name: "b", layout: .splits(.leaf("b-p1")))],
                                activeScreenID: "a", focusedPane: "a-p1")
        let provider = Panes()
        let root = LayoutRootView(model: model, contentProvider: provider)
        root.context.reduceMotionOverride = false
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        defer { window.closeAfterTest() }
        window.contentView = root
        root.layoutSubtreeIfNeeded()
        root.driver.isManual = true

        model.selectScreen("b")
        root.syncWithModel()
        for _ in 0..<3 { root.advanceFrame(1.0 / 120) }
        let incoming = try #require(root.screenViews["b"]), outgoing = try #require(root.screenViews["a"])
        let inBefore = incoming.frame.minX, outBefore = outgoing.frame.minX
        #expect(inBefore > 10, "three frames in, the new screen is still sliding in from the right (\(inBefore))")
        #expect(outBefore < -10, "and the old one sliding out to the left (\(outBefore))")

        root.needsLayout = true
        root.layoutSubtreeIfNeeded()
        #expect(abs(incoming.frame.minX - inBefore) < 1, "a layout pass does not move the incoming screen (\(inBefore) -> \(incoming.frame.minX))")
        #expect(abs(outgoing.frame.minX - outBefore) < 1, "nor the outgoing one (\(outBefore) -> \(outgoing.frame.minX))")

        // The slide goes on from there and lands in place.
        root.advanceFrame(1.0 / 120)
        #expect(incoming.frame.minX < inBefore && incoming.frame.minX > 0, "the next frame moves on toward rest (\(incoming.frame.minX))")
        for _ in 0..<240 where root.advanceFrame(1.0 / 120) {}
        #expect(incoming.frame.origin == .zero && incoming.frame.size == root.bounds.size, "it lands filling the root")
    }
}
