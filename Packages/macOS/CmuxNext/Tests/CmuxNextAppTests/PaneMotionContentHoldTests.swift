import AppKit
@testable import CmuxNextBrowser
@testable import CmuxNextLayout
import Testing

/// A panel opening beside a chat (Leo 2026-10-20: the chat's Browser, its summary side and a New
/// Tab column): the open "animates slowly, lags and destroys the overlay", the panel drawing past
/// the window's right edge. Two causes: every frame of the split spring laid the chat's page out
/// again at the frame's width, and a Chromium page (a child window) carried past the screen's
/// edge by the spring was clipped by nothing but the window's rounded corners.
@MainActor @Suite struct PaneMotionContentHoldTests {
    /// A pane host as the layout makes it (8 pt padding, 10 pt corners) on a 600 pt screen that
    /// clips its panes, as `ScreenContentView` does.
    struct Screen {
        let screen = NSView(frame: CGRect(x: 0, y: 0, width: 600, height: 300))
        let page = CEFHostView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let host: PaneHostView

        init(hostFrame: CGRect = CGRect(x: 0, y: 0, width: 400, height: 300)) {
            screen.wantsLayer = true
            screen.layer?.masksToBounds = true
            host = PaneHostView(pane: PaneID("panel"), content: page)
            host.frame = hostFrame
            host.applyShape(padding: 8, cornerRadius: 10)
            screen.addSubview(host)
            host.layoutSubtreeIfNeeded()
        }
    }

    @Test func aPageSpringingPastTheScreensEdgeIsCutAtThatEdge() throws {
        // The host's right 200 pt are past the screen's right edge.
        let column = Screen(hostFrame: CGRect(x: 400, y: 0, width: 400, height: 300))
        let shown = try #require(column.page.cmuxClipPath()?.bounds, "the page is cut at the screen's edge")
        let edge = column.page.convert(CGPoint(x: 600, y: 0), from: column.screen).x
        #expect(abs(shown.maxX - edge) < 1, "the page ends at the screen's right edge: \(shown), edge \(edge)")
    }

    @Test func aPageInsideItsScreenGetsNoExtraClip() throws {
        let column = Screen()
        let shown = try #require(column.page.cmuxClipPath()?.bounds, "the pane's rounded corners still cut the page")
        #expect(abs(shown.width - column.page.bounds.width) < 1, "\(shown)")
    }

    @Test func aShrinkingPaneKeepsItsContentWidthUntilTheSpringLands() {
        let column = Screen()
        let before = column.page.frame.size
        // The split spring starts: the chat will rest 200 pt narrower, its left edge in place.
        column.host.restSize = CGSize(width: 200, height: 300)
        column.host.restOffset = .zero
        column.host.isOnLayoutSpring = true
        column.host.frame = CGRect(x: 0, y: 0, width: 300, height: 300)
        #expect(column.page.frame.size == before, "no layout at the frame's width: \(column.page.frame)")
        #expect(column.page.frame.minX == 0, "the content rides the edge that stays")
        column.host.frame = CGRect(x: 0, y: 0, width: 200, height: 300)
        column.host.restOffset = .zero
        column.host.isOnLayoutSpring = false
        let landed: CGFloat = 184 // 200 less the 8 pt padding on each side
        #expect(column.page.frame.width == landed, "one layout at the landed size: \(column.page.frame)")
    }

    /// Leo 2026-10-21: after a restart the chat was laid out wider than its pane, pinned to its
    /// right edge, its text and composer cut off at the left. A host at its rest place and size
    /// shows its content at the clip's bounds whatever its spring flag says: held content belongs
    /// to a frame on its way, never to one that is there.
    @Test func aHostAtRestHoldsNothing() {
        let column = Screen()
        column.host.restSize = CGSize(width: 200, height: 300)
        column.host.restOffset = CGVector(dx: -200, dy: 0)
        column.host.isOnLayoutSpring = true
        // The frame is at its rest, but nothing cleared the spring flag.
        column.host.restOffset = .zero
        column.host.frame = CGRect(x: 0, y: 0, width: 200, height: 300)
        let clip = column.page.superview?.bounds ?? .zero
        #expect(column.page.frame == clip, "content held at a host at rest: \(column.page.frame) in \(clip)")
    }

    @Test func aPaneOpeningOnTheRightLaysOutAtItsRestSizeAndRidesItsRightEdge() {
        // The new pane's first frame: a sliver at its right edge, growing leftward to 400 pt.
        let column = Screen(hostFrame: CGRect(x: 580, y: 0, width: 20, height: 300))
        column.host.restSize = CGSize(width: 400, height: 300)
        column.host.restOffset = CGVector(dx: -380, dy: 0)
        column.host.isOnLayoutSpring = true
        column.host.frame = CGRect(x: 560, y: 0, width: 40, height: 300)
        column.host.restOffset = CGVector(dx: -360, dy: 0)
        column.host.frame = CGRect(x: 550, y: 0, width: 50, height: 300)
        let rest: CGFloat = 384 // 400 less the 8 pt padding on each side
        #expect(column.page.frame.width == rest, "laid out once, at its size at rest: \(column.page.frame)")
        let clip = column.page.superview?.bounds ?? .zero
        #expect(column.page.frame.maxX == clip.maxX, "the content slides in with the pane's right edge: \(column.page.frame)")
    }
}
