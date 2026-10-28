import AppKit
import CmuxNextDesign
@testable import CmuxNextTabs
import Testing

/// The tab strip's drag autoscroll is an input-driven frame client. A drag over an
/// overflowing strip runs the window's motion clock only while it sits in an edge fade, as the sidebar's
/// autoscroll does (`SidebarDragAutoscroll.update(windowPoint:)`); a drag anywhere else on the strip starts
/// no frames.
@MainActor @Suite(.serialized) struct TabStripAutoscrollFramesTests {
    @Test func aDragRunsTheClockOnlyInAnEdgeFade() throws {
        let model = TabStripModel(tabs: (0..<40).map { TabItem(id: TabID("tab\($0)"), title: "Tab \($0)") }, selectedID: TabID("tab0"))
        let strip = TabStripView.testing(model: model)
        strip.dragsWindowFromEmptySpace = false
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: TabStripView.preferredHeight), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = strip
        defer { window.orderOut(nil) }
        strip.layoutSubtreeIfNeeded()
        try #require(strip.result.isOverflowing, "40 tabs do not overflow a 400 pt strip")
        let clock = MotionClock.forView(strip)
        defer { clock.stop(strip) }
        #expect(!clock.isRunning(strip), "a strip with no drag runs the clock")

        // An external drag (a torn-out tab) over the middle of the strip: no edge fade, no frames.
        let y = strip.tabsClip.bounds.midY
        strip.phantomPoint = strip.convert(CGPoint(x: strip.viewportWidth / 2, y: y), from: strip.tabsClip)
        strip.applyFrames()
        #expect(!clock.isRunning(strip), "a drag in the middle of the strip started frames")

        // The same drag in the trailing edge fade: the clock runs.
        strip.phantomPoint = strip.convert(CGPoint(x: strip.viewportWidth - 1, y: y), from: strip.tabsClip)
        strip.applyFrames()
        #expect(clock.isRunning(strip), "a drag in the trailing edge fade does not autoscroll")
    }
}
