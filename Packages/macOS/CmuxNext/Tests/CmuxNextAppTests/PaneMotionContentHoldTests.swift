import AppKit
@testable import CmuxNextBrowser
@testable import CmuxNextLayout
import Testing

/// A panel opening beside a chat (Leo 2026-10-20): a Chromium page (a child window) carried past the
/// screen's edge by the spring must be cut at that edge. Content follows the frame live on every
/// spring frame (Lawrence 2026-10-23 replaced Leo's held content with live resize; the per-frame
/// cost is the motion benches' to keep under a frame).
@MainActor @Suite struct PaneMotionContentHoldTests {
    /// A pane host as the layout makes it (8 pt padding, 10 pt corners) on a 600 pt screen that
    /// clips its panes, as `ScreenContentView` does.
    struct Screen {
        let screen = NSView(frame: CGRect(x: 0, y: 0, width: 600, height: 300))
        let page = CEFHostView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let host: PaneHostView

        init(hostFrame: CGRect = CGRect(x: 0, y: 0, width: 400, height: 300), holdsContent: Bool = false) {
            screen.wantsLayer = true
            screen.layer?.masksToBounds = true
            host = PaneHostView(pane: PaneID("panel"), content: page, holdsContentInMotion: { holdsContent })
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

    /// Live resize (Lawrence 2026-10-23; the provider holds only agent chats): on every frame of
    /// the spring the content is laid out at exactly that frame's size, the clip's bounds (the frame
    /// less the 8 pt padding on each side), never held at its starting width.
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

    /// Content the provider holds (an agent chat): it lays out once per spring, never on every frame (Leo 2026-10-20),
    /// and that one layout is at its rest size on the spring's first frame, never at the landing: a chat beside a split
    /// opening on the right does not wait for the split to land (Leo 2026-11-05: "the main pane waits for the right
    /// pane to shift before it shifts. Like, why are you waiting?").
    @Test func withTheHoldOnAShrinkingPaneLaysItsContentOutOnceAtItsRestSizeOnTheFirstFrame() {
        let column = Screen(holdsContent: true)
        column.host.restSize = CGSize(width: 200, height: 300)
        column.host.restOffset = .zero
        column.host.isOnLayoutSpring = true
        column.host.frame = CGRect(x: 0, y: 0, width: 300, height: 300)
        #expect(column.page.frame.width == 184, "the chat waits for the landing at its start width: \(column.page.frame)")
        let clip = column.page.superview?.bounds ?? .zero
        #expect(column.page.frame.minX == clip.minX, "the chat is not pinned at the edge that stays: \(column.page.frame) in \(clip)")
        column.host.frame = CGRect(x: 0, y: 0, width: 250, height: 300)
        #expect(column.page.frame.width == 184, "the chat reflowed on a spring frame: \(column.page.frame)")
        column.host.frame = CGRect(x: 0, y: 0, width: 200, height: 300)
        column.host.isOnLayoutSpring = false
        #expect(column.page.frame.width == 184, "the landing changed the chat's layout: \(column.page.frame)")
    }

    /// An ordinary moving shrink (such as unzooming a right-hand chat) takes its rest size on its first frame too,
    /// pinned at the edge nearer its rest, as a handoff does.
    @Test func anOrdinaryMovingShrinkTakesItsRestSizeFromTheFirstFrame() {
        let column = Screen(hostFrame: CGRect(x: 400, y: 0, width: 400, height: 300), holdsContent: true)
        column.host.restSize = CGSize(width: 200, height: 300)
        column.host.restOffset = CGVector(dx: -200, dy: 0)
        column.host.isContentHandoff = false
        column.host.isOnLayoutSpring = true
        column.host.frame = CGRect(x: 300, y: 0, width: 300, height: 300)
        column.host.layoutSubtreeIfNeeded()
        #expect(column.page.frame.width == 184, "ordinary shrink waits for its landing: \(column.page.frame)")
        column.host.frame = CGRect(x: 200, y: 0, width: 200, height: 300)
        column.host.isOnLayoutSpring = false
        #expect(column.page.frame.width == 184, "ordinary shrink changed at its landing: \(column.page.frame)")
    }

    /// A handoff moves an already painted full-width chat into its narrower final pane. The first
    /// frame must use the handoff target size so the old width is never replayed at landing.
    @Test func aMovingHandoffUsesItsFinalContentSizeFromTheFirstFrame() {
        let column = Screen(hostFrame: CGRect(x: 400, y: 0, width: 400, height: 300), holdsContent: true)
        column.host.restSize = CGSize(width: 200, height: 300)
        column.host.restOffset = CGVector(dx: -200, dy: 0)
        column.host.isContentHandoff = true
        column.host.isOnLayoutSpring = true
        column.host.frame = CGRect(x: 200, y: 0, width: 200, height: 300)
        column.host.layoutSubtreeIfNeeded()
        #expect(column.page.frame.width == 184, "handoff replayed the old full-width page: \(column.page.frame)")
        column.host.isOnLayoutSpring = false
    }

    /// A right-pane close can be reopened before its spring lands. The content lays out once more, at the reopened
    /// target, when the spring retargets (a terminal hears its grid there too), never on the frames after it.
    @Test func aRetargetedSpringLaysOutOnceAtTheNewRest() {
        let column = Screen(hostFrame: CGRect(x: 0, y: 0, width: 200, height: 300), holdsContent: true)
        column.host.restSize = CGSize(width: 400, height: 300)
        column.host.restOffset = .zero
        column.host.isOnLayoutSpring = true
        column.host.announceRest()
        #expect(column.page.frame.width == 384, "the close target was not held: \(column.page.frame)")

        // Reopen before landing, then present two intermediate widths: one layout at the reopened target, then none.
        column.host.restSize = CGSize(width: 200, height: 300)
        column.host.announceRest()
        #expect(column.page.frame.width == 184, "the retarget waits for the landing: \(column.page.frame)")
        for width in [260.0, 220.0] as [CGFloat] {
            column.host.frame = CGRect(x: 0, y: 0, width: width, height: 300)
            column.host.layoutSubtreeIfNeeded()
            #expect(column.page.frame.width == 184, "retargeted content resized at \(width): \(column.page.frame)")
        }
        column.host.frame = CGRect(x: 0, y: 0, width: 200, height: 300)
        column.host.isOnLayoutSpring = false
        #expect(column.page.frame.width == 184, "the landing changed the content: \(column.page.frame)")
    }

    /// Open and close each resize the live page once, at the spring's start, never per frame or at the landing. An
    /// interruption lays it out once more, at the new target, and keeps the painted page attached throughout.
    @Test func openCloseAndInterruptedPaneMotionNeverShowsBlankOrReflowsPerFrame() {
        let column = Screen(hostFrame: CGRect(x: 0, y: 0, width: 200, height: 300), holdsContent: true)
        var sizes: [CGFloat] = []
        func record(_ label: String) {
            #expect(column.page.superview != nil, "\(label): page was detached")
            #expect(column.page.frame.width > 0, "\(label): page was blank")
            sizes.append(column.page.frame.width)
        }

        // Ordinary open and close.
        column.host.restSize = CGSize(width: 400, height: 300)
        column.host.isOnLayoutSpring = true
        column.host.announceRest()
        for width in [240.0, 300.0, 360.0] as [CGFloat] {
            column.host.frame = CGRect(x: 0, y: 0, width: width, height: 300)
            column.host.layoutSubtreeIfNeeded()
            record("open \(width)")
        }
        column.host.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        column.host.isOnLayoutSpring = false
        record("open landed")
        #expect(sizes.dropFirst().allSatisfy { $0 == sizes[0] }, "open reflowed per frame: \(sizes)")

        sizes.removeAll()
        column.host.restSize = CGSize(width: 200, height: 300)
        column.host.isOnLayoutSpring = true
        column.host.announceRest()
        for width in [360.0, 300.0, 240.0] as [CGFloat] {
            column.host.frame = CGRect(x: 0, y: 0, width: width, height: 300)
            column.host.layoutSubtreeIfNeeded()
            record("close \(width)")
        }
        column.host.frame = CGRect(x: 0, y: 0, width: 200, height: 300)
        column.host.isOnLayoutSpring = false
        record("close landed")
        #expect(Set(sizes).count == 1, "close reflowed after its start: \(sizes)")

        // Open, then close before landing: one layout at the open's start, one at the retarget.
        sizes.removeAll()
        column.host.restSize = CGSize(width: 400, height: 300)
        column.host.isOnLayoutSpring = true
        column.host.announceRest()
        column.host.frame = CGRect(x: 0, y: 0, width: 300, height: 300)
        column.host.layoutSubtreeIfNeeded()
        record("interrupted open")
        column.host.restSize = CGSize(width: 200, height: 300)
        column.host.announceRest()
        for width in [260.0, 220.0] as [CGFloat] {
            column.host.frame = CGRect(x: 0, y: 0, width: width, height: 300)
            column.host.layoutSubtreeIfNeeded()
            record("interrupted close \(width)")
        }
        column.host.frame = CGRect(x: 0, y: 0, width: 200, height: 300)
        column.host.isOnLayoutSpring = false
        record("interrupted landed")
        #expect(Set(sizes).count == 2, "interrupted motion reflowed per frame: \(sizes)")
    }
    /// A split's new pane starts as a zero-wide sliver (`PaneArrival`). While it is narrower than
    /// twice the padding its clip is zero wide; the page still lays out once, at its size at rest,
    /// and never resizes on the way (Leo, ask-7d6c0da7c9: "the speedy non laggy animation for
    /// opening up a new thing on the right").
    @Test func aPaneGrowingFromASliverNeverResizesItsPage() {
        let column = Screen(hostFrame: CGRect(x: 600, y: 0, width: 0, height: 300), holdsContent: true)
        column.host.restSize = CGSize(width: 400, height: 300)
        column.host.restOffset = CGVector(dx: -400, dy: 0)
        column.host.isContentHandoff = true
        column.host.isOnLayoutSpring = true
        var widths: [CGFloat] = []
        for width: CGFloat in [3, 7, 12, 15, 16, 24, 60, 180, 330, 399.5] {
            column.host.restOffset = CGVector(dx: -(400 - width), dy: 0)
            column.host.frame = CGRect(x: 600 - width, y: 0, width: width, height: 300)
            widths.append(column.page.frame.width)
        }
        let rest: CGFloat = 384 // 400 less the 8 pt padding on each side
        #expect(widths.allSatisfy { $0 == rest }, "the page resized while the pane grew: \(widths)")
    }
}
