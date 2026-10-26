import AppKit
@testable import CmuxNextDesign
import CmuxNextInput
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Testing

/// The agent cursor's tag hover and the thin scroller's proximity hover once per frame (feature
/// `pointerFrameHover`, p04-input-036) on p04-input-030's coalescer, as Chromium delivers rAF-aligned
/// moves (`third_party/blink/renderer/platform/widget/input/main_thread_event_queue.cc`): the first
/// move of a frame interval acts in its own turn, the rest once at the frame, at the latest point.
/// An exit drops the waiting moves; a press lands them first.
@MainActor @Suite(.serialized) struct OverlayHoverPerFrameTests {
    static func move(_ type: NSEvent.EventType = .mouseMoved, at point: NSPoint, in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    static func exit(at point: NSPoint, in window: NSWindow) throws -> NSEvent {
        try #require(exitEvent(at: point, in: window))
    }

    static func exitEvent(at point: NSPoint, in window: NSWindow) -> NSEvent? {
        NSEvent.enterExitEvent(with: .mouseExited, location: point, modifierFlags: [], timestamp: 0,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)
    }

    // MARK: Agent cursor tags

    final class Tags: AgentCursorTagSource {
        var tags: [AgentCursorTagTarget] = [
            AgentCursorTagTarget(id: "s1", frame: CGRect(x: 100, y: 50, width: 120, height: 22),
                                 label: "a201 · cursor-gallery", help: "Go to cursor-gallery"),
        ]
        var hovered: [String?] = []
        func agentCursorTags() -> [AgentCursorTagTarget] { tags }
        func pressAgentCursorTag(_ id: String) {}
        func hoverAgentCursorTag(_ id: String?) { hovered.append(id) }
    }

    @MainActor final class Cursor {
        let window: NSWindow
        let frames: PointerFrameTestRig
        let tags: Tags
        let host: WindowOverlayHost
        let carrier: AgentCursorCarrierView

        init() throws {
            _ = NSApplication.shared
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                                  backing: .buffered, defer: true)
            let frames = PointerFrameTestRig()
            let tags = Tags()
            let host = WindowOverlayHost.host(for: window)
            host.hoverFrames = frames.coalescers
            host.agentCursorTags = tags
            _ = host.agentCursorLayer
            carrier = try #require(host.agentCursorCarrier)
            self.window = window
            self.frames = frames
            self.tags = tags
            self.host = host
        }

        /// A y-down cursor-layer point in window coordinates.
        func point(x: CGFloat, y: CGFloat) -> NSPoint {
            carrier.convert(NSPoint(x: x, y: carrier.bounds.height - y), to: nil)
        }

        var onTag: NSPoint { point(x: 150, y: 61) }
        var offTag: NSPoint { point(x: 10, y: 10) }

        func close() {
            if let exit = OverlayHoverPerFrameTests.exitEvent(at: offTag, in: window) { carrier.mouseExited(with: exit) }
            host.tearDown()
            frames.close()
        }
    }

    /// Eight moves in one frame over and off a tag: the leading move (off) hovers nothing, the frame
    /// hovers the tag under the last move. Two hit tests, no more.
    @Test func eightMovesInOneFrameHoverTheTagUnderTheLatestMoveTwice() throws {
        let cursor = try Cursor()
        defer { cursor.close() }
        #expect(cursor.carrier.hoverMoves.frames === cursor.frames.coalescers, "the carrier did not take the host's frames")
        for step in 0..<8 {
            cursor.carrier.mouseMoved(with: try Self.move(at: step.isMultiple(of: 2) ? cursor.offTag : cursor.onTag, in: cursor.window))
        }
        #expect(cursor.tags.hovered.isEmpty, "a move after the leading one hovered before the frame")
        #expect(cursor.carrier.hoverMoves.hasPending)
        cursor.frames.frame()
        #expect(cursor.tags.hovered == ["s1"])
        #expect(cursor.carrier.hoverMoves.maxDeliveriesPerFrame == 2)
    }

    /// Leaving the carrier drops the waiting moves: a frame after the exit hovers no tag.
    @Test func anExitDropsTheWaitingMoves() throws {
        let cursor = try Cursor()
        defer { cursor.close() }
        cursor.carrier.mouseMoved(with: try Self.move(at: cursor.offTag, in: cursor.window))
        cursor.carrier.mouseMoved(with: try Self.move(at: cursor.onTag, in: cursor.window))
        cursor.carrier.mouseExited(with: try Self.exit(at: cursor.offTag, in: cursor.window))
        #expect(!cursor.carrier.hoverMoves.hasPending)
        cursor.frames.frame()
        #expect(cursor.tags.hovered.isEmpty, "a move from before the exit hovered the tag")
    }

    // MARK: Thin scroller proximity

    @MainActor final class Scroller {
        let window: NSWindow
        let frames: PointerFrameTestRig
        let scrollView: NSScrollView
        let scroller: ThinScroller
        let proximity: ThinScrollerProximity
        /// The window's overlay host: it carries the window's frames (the App sets them on a main window).
        let host: WindowOverlayHost

        init() throws {
            _ = NSApplication.shared
            let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 240, height: 200), styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let frames = PointerFrameTestRig()
            let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 240, height: 200))
            scrollView.hasVerticalScroller = true
            scrollView.verticalScroller = ThinScroller(frame: .zero, clock: ManualClock(), notificationCenter: NotificationCenter())
            SystemScrollers.followThin(scrollView)
            scrollView.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 800))
            window.contentView = scrollView
            scrollView.tile()
            let scroller = try #require(scrollView.verticalScroller as? ThinScroller)
            scroller.isEnabled = true
            scroller.knobProportion = 0.25
            let host = WindowOverlayHost.host(for: window)
            host.hoverFrames = frames.coalescers
            proximity = try #require(scroller.proximity)
            self.host = host
            self.window = window
            self.frames = frames
            self.scrollView = scrollView
            self.scroller = scroller
        }

        /// Beside the trailing edge, and in the middle of the view, in window coordinates.
        var near: NSPoint { scrollView.convert(NSPoint(x: scrollView.bounds.maxX - 3, y: 100), to: nil) }
        var far: NSPoint { scrollView.convert(NSPoint(x: 20, y: 100), to: nil) }

        func close() {
            if let exit = OverlayHoverPerFrameTests.exitEvent(at: far, in: window) { proximity.mouseExited(with: exit) }
            host.tearDown()
            frames.close()
            window.close()
        }
    }

    /// Eight moves in one frame, the leading one far from the edge and the last one near it: the knob
    /// stays thin until the frame, then widens once.
    @Test func eightMovesInOneFrameWidenTheKnobAtTheFrame() throws {
        let rig = try Scroller()
        defer { rig.close() }
        for step in 0..<8 { rig.proximity.mouseMoved(with: try Self.move(at: step.isMultiple(of: 2) ? rig.far : rig.near, in: rig.window)) }
        #expect(rig.proximity.moves.frames === rig.frames.coalescers, "the proximity did not take its window's frames")
        #expect(!rig.scroller.isKnobExpanded, "a move after the leading one widened the knob before the frame")
        #expect(rig.proximity.moves.hasPending)
        rig.frames.frame()
        #expect(rig.scroller.isKnobExpanded, "the frame did not report the latest move, near the edge")
        #expect(rig.proximity.moves.maxDeliveriesPerFrame == 2)
    }

    /// A lone move near the edge widens the knob in its own turn.
    @Test func aSingleMoveNearTheEdgeWidensTheKnobAtOnce() throws {
        let rig = try Scroller()
        defer { rig.close() }
        rig.proximity.mouseMoved(with: try Self.move(at: rig.near, in: rig.window))
        #expect(rig.scroller.isKnobExpanded)
        #expect(!rig.proximity.moves.hasPending)
    }

    /// A window whose host has no frames (the feature off, a panel) reports each move at once.
    @Test func withoutTheWindowsFramesEachMoveReports() throws {
        let rig = try Scroller()
        defer { rig.close() }
        rig.host.hoverFrames = nil
        rig.proximity.mouseMoved(with: try Self.move(at: rig.far, in: rig.window))
        rig.proximity.mouseMoved(with: try Self.move(at: rig.near, in: rig.window))
        #expect(rig.scroller.isKnobExpanded, "the second move waited with no frames")
        #expect(rig.proximity.moves.frames == nil)
    }

    /// Leaving the view drops the waiting moves: the frame after the exit does not widen the knob.
    @Test func anExitDropsTheWaitingProximityMoves() throws {
        let rig = try Scroller()
        defer { rig.close() }
        rig.proximity.mouseMoved(with: try Self.move(at: rig.far, in: rig.window))
        rig.proximity.mouseMoved(with: try Self.move(at: rig.near, in: rig.window))
        rig.proximity.mouseExited(with: try Self.exit(at: rig.far, in: rig.window))
        rig.frames.frame()
        #expect(!rig.scroller.isKnobExpanded, "a move from before the exit widened the knob")
    }
}
