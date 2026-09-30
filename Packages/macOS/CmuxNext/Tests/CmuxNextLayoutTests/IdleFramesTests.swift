import AppKit
import CmuxNextWakeups
import Testing
@testable import CmuxNextLayout

/// The layout ticks only while something moves (architecture.md 5).
@MainActor
struct IdleFramesTests {
    /// Regression (state-audit L1): while a divider gesture was active the
    /// layout requested a frame every vsync even when the pointer held
    /// still, and when the gesture never ended (its handle view removed
    /// mid-drag) the window's display link spun at 120 Hz forever.
    @Test func aHeldGestureWithNothingMovingStopsTheFrames() {
        let model = LayoutModel(screens: [LayoutScreen(id: "s", name: "", layout: .splits(.leaf("a")))])
        let provider = IdleProvider()
        let view = LayoutRootView(model: model, contentProvider: provider)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 500), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        defer { window.close() }
        guard view.driver.isAttached else { return }

        model.setGestureActive(true)
        view.context.requestFrames()
        #expect(view.driver.isRunning)
        let scheduler = FrameScheduler.forWindow(window)
        for _ in 0..<5 { scheduler.frameDidFire() }
        #expect(!view.driver.isRunning)
        #expect(scheduler.activeClients.isEmpty)
        model.setGestureActive(false)
        withExtendedLifetime(provider) {}
    }
}

private final class IdleProvider: LayoutPaneContentProvider {
    func makeContentView(for pane: PaneID) -> NSView { NSView() }
    func releaseContentView(_ view: NSView, for pane: PaneID) {}
}
