import AppKit
@testable import CmuxNextDesign
import Testing

/// A pane that parks is hidden in place (PaneContentView+Parking, WindowRootView.withdraw), and an
/// indicator inside it kept its Core Animation loop running on a hidden layer: the window was still
/// visible, and only the sidebar list and tab strip tell their indicators when they hide (hq#3716).
@MainActor @Suite(.serialized) struct StatusIndicatorHiddenAncestorTests {
    private struct Fixture {
        let window: NSWindow
        let pane: NSView
        let indicator: StatusIndicatorView

        init(paneHidden: Bool) {
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            let content = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
            window.contentView = content
            pane = NSView(frame: content.bounds)
            pane.isHidden = paneHidden
            content.addSubview(pane)
            indicator = StatusIndicatorView(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
            pane.addSubview(indicator)
            // The test window is never ordered in; stand in for a visible one.
            indicator.isWindowVisible = true
            indicator.configure(.working)
        }
    }

    private func moving(_ body: () throws -> Void) rethrows {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        try body()
    }

    @Test func parkingThePaneStopsTheLoopAndShowingItStartsItAgain() throws {
        try moving {
            let fixture = Fixture(paneHidden: false)
            try #require(fixture.indicator.indicator.runningAnimation != nil, "a working indicator on screen should loop")
            fixture.pane.isHidden = true
            #expect(fixture.indicator.indicator.runningAnimation == nil, "a parked pane's indicator keeps looping")
            fixture.pane.isHidden = false
            #expect(fixture.indicator.indicator.runningAnimation != nil, "the indicator did not loop again when shown")
        }
    }

    @Test func anIndicatorConfiguredWhileParkedLoopsOnceShown() {
        moving {
            let fixture = Fixture(paneHidden: true)
            #expect(fixture.indicator.indicator.runningAnimation == nil)
            #expect(fixture.indicator.showsGlyph, "the mark still shows; only its loop waits")
            fixture.pane.isHidden = false
            #expect(fixture.indicator.indicator.runningAnimation != nil)
        }
    }
}
