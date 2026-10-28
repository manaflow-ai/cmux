import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextLaunch
@testable import CmuxNextTabs
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Testing

/// A pane's launch image holds startup only while the pane is in its window: a
/// pane that leaves its window or is torn down with its image up ends its share with `noVisiblePane`,
/// so startup completes then, not at the 10 s failsafe.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct PaneLaunchImageHoldTests {
    @Test func aPaneThatLeavesItsWindowWithItsImageUpEndsItsShare() {
        let f = PaneImageFixture()
        defer { f.tearDown() }
        f.pane.showLaunchImage(PaneImageFixture.image, hold: f.hold)
        f.scheduler.complete()
        #expect(f.scheduler.startup.heldRefs == ["LaunchImageHold.images"])
        // The pane leaves its window (its window closed); the test still holds the pane.
        f.window.contentView = nil
        f.scheduler.hand.drain()
        #expect(!f.hold.isHolding)
        #expect(f.scheduler.startup.completion?.reason == .noVisiblePane, "a closed pane is not a failsafe completion")
    }

    @Test func aPaneTornDownWithItsImageUpEndsItsShare() {
        let f = PaneImageFixture()
        defer { f.tearDown() }
        f.pane.showLaunchImage(PaneImageFixture.image, hold: f.hold)
        f.scheduler.complete()
        // PaneController.teardown: the pane's tree no longer lists it.
        f.pane.detachContent()
        f.scheduler.hand.drain()
        #expect(!f.hold.isHolding)
        #expect(f.scheduler.startup.completion?.reason == .noVisiblePane)
    }

    @Test func theImagePaintingEndsTheShareOnce() {
        let f = PaneImageFixture()
        defer { f.tearDown() }
        f.pane.showLaunchImage(PaneImageFixture.image, hold: f.hold)
        f.pane.clearLaunchImage()
        f.window.contentView = nil
        f.scheduler.complete()
        #expect(f.scheduler.startup.completion?.reason == .firstFrameCommitted, "leaving the window after the image went ends nothing more")
    }
}

/// A pane in a window, with a launch image hold on the shared test scheduler.
@MainActor
private final class PaneImageFixture {
    static let image = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { @Sendable rect in
        NSColor.gray.setFill()
        rect.fill()
        return true
    }

    let scheduler: StartupTestScheduler
    let hold: LaunchImageHold
    let reveal: LaunchReveal
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                          backing: .buffered, defer: false)
    let pane: PaneContentView

    init() {
        let scheduler = StartupTestScheduler(), reveal = LaunchReveal(deadline: .seconds(60))
        hold = LaunchImageHold(startup: scheduler.startup)
        pane = .testing(stripModel: TabStripModel(tabs: [TabItem(id: TabID("a"), title: "A")]), reveal: reveal)
        (self.scheduler, self.reveal) = (scheduler, reveal)
        window.isReleasedWhenClosed = false
        pane.frame = window.contentLayoutRect
        window.contentView = pane
    }

    func tearDown() {
        window.contentView = nil
        window.close()
    }
}
