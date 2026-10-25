import AppKit
@testable import CmuxNextApp
@testable import CmuxNextBrowser
import CmuxNextDesign
@testable import CmuxNextLayout
import Testing
import CmuxNextWakeupsTestSupport

/// The strip scrollbar stays above a browser page (cx-6so.44, dock-column.md Known gaps). It draws
/// along the bottom of the strip, over the panes there, but a Chromium page is a child window above
/// the window's own views: a page at the bottom of the strip hid the thumb and took its clicks. The
/// fork leaves a page's occlusion rects uncovered and sends the mouse there to the window, so the
/// shown thumb must be one of them, and only while it shows.
@MainActor @Suite struct StripScrollbarAbovePageTests {
    /// The app's window with a page filling it and the strip scrollbar along its bottom, as the
    /// layout places them (the band is in the page's superview).
    struct Strip {
        let window: ShellWindow
        let page: CEFHostView
        let bar = StripScrollbarView(hideClock: ManualClock())

        init() {
            _ = NSApplication.shared
            let content = NSView(frame: CGRect(x: 0, y: 0, width: 800, height: 500))
            window = ShellWindow(contentRect: content.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = content
            _ = WindowOverlayHost.host(for: window)
            page = CEFHostView(frame: content.bounds)
            content.addSubview(page)
            content.addSubview(bar)
        }

        /// A strip twice the viewport's width, so the thumb is half the track.
        func show(_ mode: StripScrollbarMode, offset: CGFloat = 0) {
            let band = CGRect(x: 16, y: 0, width: 768, height: StripScrollbarView.bandHeight)
            bar.update(StripScrollbarView.Input(mode: mode, band: band, offset: offset, contentWidth: 1600,
                                                viewportWidth: 800, snaps: [0, 800]), scrolled: true)
        }

        /// What the fork leaves uncovered on the page.
        var holes: [CGRect] { (page.cmuxOcclusionRects() as? [NSValue])?.map(\.rectValue) ?? [] }

        /// The thumb's band in the page's coordinates, or nil when there is none.
        var thumb: CGRect? { bar.thumbRect.map { page.convert($0, from: bar) } }
    }

    static func same(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 1 && abs(a.minY - b.minY) < 1 && abs(a.width - b.width) < 1 && abs(a.height - b.height) < 1
    }

    @Test func theShownThumbIsAHoleInThePageAndFollowsTheScroll() throws {
        let strip = Strip()
        strip.show(.always)
        let thumb = try #require(strip.thumb, "a strip wider than its viewport has a thumb")
        #expect(strip.holes.contains { Self.same($0, thumb) }, "the page leaves the thumb uncovered: \(strip.holes), thumb \(thumb)")

        strip.show(.always, offset: 800)
        let moved = try #require(strip.thumb)
        #expect(moved.minX > thumb.minX + 100, "scrolled to the end, the thumb moved right: \(moved)")
        #expect(strip.holes.contains { Self.same($0, moved) }, "the hole follows the thumb: \(strip.holes), thumb \(moved)")
        #expect(!strip.holes.contains { Self.same($0, thumb) }, "no hole stays where the thumb was: \(strip.holes)")
    }

    @Test func aHiddenScrollbarLeavesThePageWhole() {
        let strip = Strip()
        strip.show(.always)
        strip.show(.off)
        #expect(strip.holes.isEmpty, "the scrollbar setting is off: \(strip.holes)")

        strip.show(.always)
        // A split screen hides the bar without an update (`updateScrollbar`).
        strip.bar.isHidden = true
        #expect(strip.holes.isEmpty, "a hidden bar: \(strip.holes)")

        strip.bar.isHidden = false
        strip.bar.removeFromSuperview()
        #expect(strip.holes.isEmpty, "a bar that left the window: \(strip.holes)")
    }
}

/// A screen switch or an empty workspace hides the view holding the bar, not the bar (review of
/// #20759): the old screen's thumb left a hole in the page, the new screen's had none.
@MainActor @Suite struct StripScrollbarHiddenScreenTests {
    @Test func aHiddenScreenLeavesNoHoleAndShowsItsThumbAgain() throws {
        let strip = StripScrollbarAbovePageTests.Strip()
        // The bar in its screen's view, as `ScreenContentView` holds it.
        let screen = NSView(frame: strip.page.frame)
        strip.page.superview?.addSubview(screen)
        screen.addSubview(strip.bar)
        strip.show(.always)
        let thumb = try #require(strip.thumb)
        #expect(strip.holes.contains { StripScrollbarAbovePageTests.same($0, thumb) }, "\(strip.holes)")

        screen.isHidden = true
        #expect(strip.holes.isEmpty, "a hidden screen's thumb: \(strip.holes)")

        screen.isHidden = false
        #expect(strip.holes.contains { StripScrollbarAbovePageTests.same($0, thumb) }, "shown again: \(strip.holes)")
    }
}
