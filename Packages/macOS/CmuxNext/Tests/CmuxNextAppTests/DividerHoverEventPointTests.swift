import AppKit
@testable import CmuxNextLayout
import CmuxNextWakeups
import Testing

/// A divider handle's enter or exit hovers from that event's own point, not from the live cursor:
/// the enter below lands on the handle wherever the real mouse rests, and the
/// exit off it clears the hover.
@MainActor @Suite(.serialized)
struct DividerHoverEventPointTests {
    final class Panes: LayoutPaneContentProvider {
        func makeContentView(for pane: PaneID) -> NSView { NSView() }
    }

    /// Divider hover asks for the key window; a test host never activates, so this one says it is.
    final class KeyWindow: NSWindow {
        override var isKeyWindow: Bool { true }
    }

    @Test func anEnterHoversTheHandleFromItsPointAndAnExitClearsIt() throws {
        _ = NSApplication.shared
        let layout = ScreenLayout.columns([
            LayoutColumn(id: "c1", width: 1.0, root: .split("x", axis: .horizontal, ratio: 0.5, a: .leaf("p1"), b: .leaf("p2"))),
        ])
        let model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: layout)], activeScreenID: "s", focusedPane: "p1")
        let provider = Panes()
        let root = LayoutRootView(model: model, contentProvider: provider, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        root.context.reduceMotionOverride = true
        let visible = NSScreen.screens.first?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let window = KeyWindow(contentRect: CGRect(x: visible.maxX - 660, y: visible.minY + 60, width: 600, height: 400),
                               styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        // Above the test host's other windows there, so the topmost check finds this one.
        window.level = .floating
        window.contentView = root
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        root.layoutSubtreeIfNeeded()
        root.driver.isManual = true
        for _ in 0..<600 where root.advanceFrame(1.0 / 120) {}
        let screen = try #require(root.screenViews["s"])
        let handle = try #require(screen.dividerViews[.split("x")])
        let band = screen.convert(handle.cursorRectInBounds, from: handle)
        try #require(band.width > 1 && band.height > 1, "the split's divider shows: \(band)")

        let on = screen.convert(CGPoint(x: band.midX, y: band.midY), to: nil)
        handle.mouseEntered(with: try Self.event(.mouseEntered, at: on, in: window))
        #expect(handle.isHovered, "the enter's point is on the handle")

        let off = screen.convert(CGPoint(x: band.minX - 80, y: band.midY), to: nil)
        handle.mouseExited(with: try Self.event(.mouseExited, at: off, in: window))
        #expect(!handle.isHovered, "the exit's point is off the handle")
    }

    static func event(_ type: NSEvent.EventType, at point: CGPoint, in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.enterExitEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                            context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
    }
}
