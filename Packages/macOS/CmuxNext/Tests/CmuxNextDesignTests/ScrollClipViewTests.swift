import AppKit
@testable import CmuxNextDesign
import Testing

/// The clip pushes its scrolls and resizes to its owner from its own setters (p03-rendering-039), the way
/// Chromium's `views::ScrollView` runs its contents-scrolled callbacks: no NotificationCenter observer,
/// one call per real change, none for a setter that changes nothing.
@MainActor
struct ScrollClipViewTests {
    private func scrollView() -> (NSScrollView, ScrollClipView) {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let clip = ScrollClipView()
        scrollView.contentView = clip
        scrollView.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 1_000))
        scrollView.tile()
        return (scrollView, clip)
    }

    @Test func aScrollReportsOnceAndNoMoveReportsNothing() {
        let (_, clip) = scrollView()
        var scrolls = 0
        clip.onScroll = { scrolls += 1 }
        clip.scroll(to: NSPoint(x: 0, y: 300))
        #expect(scrolls == 1)
        #expect(clip.bounds.origin.y == 300)
        clip.scroll(to: NSPoint(x: 0, y: 300))
        #expect(scrolls == 1, "scrolling to where it already is is not a scroll")
    }

    @Test func aDirectBoundsOriginMoveReportsAScroll() {
        let (_, clip) = scrollView()
        var scrolls = 0
        clip.onScroll = { scrolls += 1 }
        clip.setBoundsOrigin(NSPoint(x: 0, y: 120))
        #expect(scrolls == 1)
    }

    @Test func aTileToANewSizeReportsAResizeAndASameSizeTileNothing() {
        let (scrollView, clip) = scrollView()
        var resizes = 0
        clip.onResize = { resizes += 1 }
        scrollView.frame.size = NSSize(width: 100, height: 160)
        scrollView.tile()
        #expect(resizes == 1)
        #expect(clip.frame.height == 160)
        scrollView.tile()
        #expect(resizes == 1, "a tile that keeps the size is not a resize")
    }
}
