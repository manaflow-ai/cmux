import AppKit
@testable import CmuxNextBrowser
@testable import CmuxNextLayout
import Testing

/// A panel opening beside a chat (Leo 2026-10-20): a Chromium page (a child window) carried past the
/// screen's edge by the spring must be cut at that edge. Content follows the frame live on every
/// spring frame (Lawrence 2026-10-23 replaced Leo's held content with live resize; the per-frame
/// cost is the motion benches' to keep under a frame). Since 2026-11-11 that is every kind of content: no
/// provider can ask the host to hold its content on a split, a close or a zoom (Lawrence: "all must have
/// smooth transition"), so each test here is the one rule, with no switch.
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

    /// Live resize (Lawrence 2026-10-23; every kind since 2026-11-11): on every frame of
    /// the spring the content is laid out at exactly that frame's size, the clip's bounds (the frame
    /// less the 8 pt padding on each side), never held at its starting width or at its rest width.
    @Test func aShrinkingPaneLaysItsContentOutAtEachFramesSize() {
        let column = Screen()
        column.host.restSize = CGSize(width: 200, height: 300)
        column.host.restOffset = .zero
        column.host.isOnLayoutSpring = true
        for width in [360.0, 300, 240, 200] as [CGFloat] {
            column.host.frame = CGRect(x: 0, y: 0, width: width, height: 300)
            column.host.layoutSubtreeIfNeeded()
            let clip = column.page.superview?.bounds ?? .zero
            #expect(column.page.frame == clip, "content at the frame's size at \(width): \(column.page.frame) in \(clip)")
            #expect(column.page.frame.width == width - 16)
        }
        column.host.isOnLayoutSpring = false
        #expect(column.page.frame.width == 184, "landed at its rest size: \(column.page.frame)")
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

    /// A pane opening on the right grows from a sliver: its content follows each frame's size live
    /// (the grid or page reflows with the frame, no held width pinned to an edge).
    @Test func aPaneOpeningOnTheRightLaysOutAtEachFramesSize() {
        let column = Screen(hostFrame: CGRect(x: 580, y: 0, width: 20, height: 300))
        column.host.restSize = CGSize(width: 400, height: 300)
        column.host.restOffset = CGVector(dx: -380, dy: 0)
        column.host.isOnLayoutSpring = true
        for (x, width) in [(560.0, 40.0), (550, 50), (400, 200), (200, 400)] as [(CGFloat, CGFloat)] {
            column.host.restOffset = CGVector(dx: 200 - x, dy: 0)
            column.host.frame = CGRect(x: x, y: 0, width: width, height: 300)
            column.host.layoutSubtreeIfNeeded()
            let clip = column.page.superview?.bounds ?? .zero
            #expect(column.page.frame == clip, "content at the frame's size at \(width): \(column.page.frame) in \(clip)")
        }
    }

    /// A pane that moves while it narrows (unzooming a right-hand chat): its content has the frame's size in every frame,
    /// never its rest size from the first frame (the hold an agent chat had until 2026-11-11).
    @Test func aMovingShrinkLaysItsContentOutAtEachFramesSize() {
        let column = Screen(hostFrame: CGRect(x: 400, y: 0, width: 400, height: 300))
        column.host.restSize = CGSize(width: 200, height: 300)
        column.host.restOffset = CGVector(dx: -200, dy: 0)
        column.host.isOnLayoutSpring = true
        column.host.announceRest()
        #expect(column.page.frame.width == 384, "the spring's start resized the content before its pane moved: \(column.page.frame)")
        for (x, width) in [(300.0, 300.0), (240, 240), (210, 210)] as [(CGFloat, CGFloat)] {
            column.host.restOffset = CGVector(dx: 200 - x, dy: 0)
            column.host.frame = CGRect(x: x, y: 0, width: width, height: 300)
            column.host.layoutSubtreeIfNeeded()
            let clip = column.page.superview?.bounds ?? .zero
            #expect(column.page.frame == clip, "content at the frame's size at \(width): \(column.page.frame) in \(clip)")
            #expect(column.page.frame.width == width - 16)
        }
        column.host.restOffset = .zero
        column.host.frame = CGRect(x: 200, y: 0, width: 200, height: 300)
        column.host.isOnLayoutSpring = false
        #expect(column.page.frame.width == 184, "landed at its rest size: \(column.page.frame)")
    }

    /// A handoff moves an already painted full-width chat into its narrower final pane, whose frame has the final size
    /// from the first frame: the content has that size there, so the old width is never replayed at landing.
    @Test func aMovingHandoffUsesItsFinalContentSizeFromTheFirstFrame() {
        let column = Screen(hostFrame: CGRect(x: 400, y: 0, width: 400, height: 300))
        column.host.restSize = CGSize(width: 200, height: 300)
        column.host.restOffset = CGVector(dx: -200, dy: 0)
        column.host.isOnLayoutSpring = true
        column.host.frame = CGRect(x: 200, y: 0, width: 200, height: 300)
        column.host.layoutSubtreeIfNeeded()
        #expect(column.page.frame.width == 184, "handoff replayed the old full-width page: \(column.page.frame)")
        column.host.isOnLayoutSpring = false
    }

    /// Open, close, and a close that a reopen interrupts before it lands (#26118): the painted page stays attached and
    /// never blank, and in every frame, the retarget's too, it has that frame's size. No frame shows a size the pane does
    /// not have (before 2026-11-11 an agent chat took its rest size at each start and kept the larger one to the landing).
    @Test func openCloseAndInterruptedPaneMotionFollowTheFrameAndNeverShowBlank() {
        let column = Screen(hostFrame: CGRect(x: 0, y: 0, width: 200, height: 300))
        func present(_ label: String, _ width: CGFloat) {
            column.host.frame = CGRect(x: 0, y: 0, width: width, height: 300)
            column.host.layoutSubtreeIfNeeded()
            #expect(column.page.superview != nil, "\(label) \(width): page was detached")
            let clip = column.page.superview?.bounds ?? .zero
            #expect(column.page.frame == clip && clip.width == width - 16, "\(label) \(width): the page is at \(column.page.frame) in \(clip)")
        }
        func start(_ label: String, rest: CGFloat) {
            let before = column.page.frame
            column.host.restSize = CGSize(width: rest, height: 300)
            column.host.isOnLayoutSpring = true
            column.host.announceRest()
            #expect(column.page.frame == before, "\(label): the start of the spring resized the page to \(column.page.frame), from \(before)")
        }

        // Ordinary open and close.
        start("open", rest: 400)
        for width in [240.0, 300.0, 360.0, 400.0] as [CGFloat] { present("open", width) }
        column.host.isOnLayoutSpring = false
        #expect(column.page.frame.width == 384, "open landed at \(column.page.frame)")

        start("close", rest: 200)
        for width in [360.0, 300.0, 240.0, 200.0] as [CGFloat] { present("close", width) }
        column.host.isOnLayoutSpring = false
        #expect(column.page.frame.width == 184, "close landed at \(column.page.frame)")

        // Open, then close before landing: the retarget changes no size, and the frames after follow as before.
        start("interrupted open", rest: 400)
        present("interrupted open", 300)
        start("retarget", rest: 200)
        for width in [260.0, 220.0, 200.0] as [CGFloat] { present("interrupted close", width) }
        column.host.isOnLayoutSpring = false
        #expect(column.page.frame.width == 184, "the interrupted close landed at \(column.page.frame)")
    }
}
