import AppKit
@testable import CmuxNextHome
import Testing

/// The Home list has two widths, as Messages' sidebar on macOS 26 (the user's recording, 2026-11-24: "lets jus
/// copy how apple does it"): the avatar strip and the full list from its minimum up. A drag or a saved width
/// between them snaps to one or the other; nothing draws a list between the two.
@MainActor
struct HomeSidebarSnapTests {
    /// Messages' resistance (measured 2026-11-24): 17 pt past the edge either way, nothing between the two widths.
    @Test func aDragSnapsSeventeenPointsPastTheEdge() {
        let strip = HomeSidebarWidth.minimum, full = HomeSidebarWidth.fullMinimum, r = HomeSidebarWidth.snapResistance
        #expect(r == 17)
        // From the full list: it follows the pointer, holds at its minimum, then snaps.
        #expect(HomeSidebarWidth.snap(full + 40, from: full + 60) == full + 40)
        #expect(HomeSidebarWidth.snap(full - 1, from: full) == full)
        #expect(HomeSidebarWidth.snap(full - r + 1, from: full) == full)
        #expect(HomeSidebarWidth.snap(full - r - 1, from: full) == strip)
        // From the strip: it holds, then snaps to the full list (or the pointer, past its minimum).
        #expect(HomeSidebarWidth.snap(strip + r - 1, from: strip) == strip)
        #expect(HomeSidebarWidth.snap(strip + r + 1, from: strip) == full)
        #expect(HomeSidebarWidth.snap(full + 30, from: strip) == full + 30)
        // Left of the strip: the strip (no drag closes the list).
        #expect(HomeSidebarWidth.snap(10, from: strip) == strip)
    }

    @Test(arguments: [100, 140, 200, 260, 300, 325] as [CGFloat])
    func aWidthUnderTheFullListIsTheStrip(_ width: CGFloat) {
        #expect(HomeSidebarWidth.clamp(width, window: 1400) == HomeSidebarWidth.minimum)
    }

    @Test func aWindowTooNarrowForTheFullListKeepsTheStrip() {
        // Half of 600 is under the full list's minimum.
        #expect(HomeSidebarWidth.clamp(400, window: 600) == HomeSidebarWidth.minimum)
        #expect(HomeSidebarWidth.clamp(400, window: 1400) == 400)
    }

    /// The divider's drag lands on the snap from the list's width now, and a window with no room for the full list keeps
    /// the strip.
    @Test func theDividerDragSnaps() {
        let home = HomeSidebarView(frame: NSRect(x: 0, y: 0, width: 328, height: 600))
        let split = HomeSidebarSplitView(sidebar: home, content: NSView(), widths: HomeSidebarWidth(defaults: UserDefaults(suiteName: "snap-tests")!))
        split.frame = NSRect(x: 0, y: 0, width: 1400, height: 600)
        split.layoutSubtreeIfNeeded()
        let full = HomeSidebarWidth.fullMinimum
        #expect(split.splitView(split, constrainSplitPosition: full - 10, ofSubviewAt: 0) == full)
        #expect(split.splitView(split, constrainSplitPosition: 420, ofSubviewAt: 0) == 420)
        // Past the widest (half of 1400) the list stays at the widest, never the strip.
        let widest = HomeSidebarWidth.clamp(.greatestFiniteMagnitude, window: 1400 - split.dividerThickness)
        #expect(widest > full)
        #expect(split.splitView(split, constrainSplitPosition: 750, ofSubviewAt: 0) == widest)
        split.frame = NSRect(x: 0, y: 0, width: 600, height: 600)
        #expect(split.splitView(split, constrainSplitPosition: 250, ofSubviewAt: 0) == HomeSidebarWidth.minimum)
    }
}
