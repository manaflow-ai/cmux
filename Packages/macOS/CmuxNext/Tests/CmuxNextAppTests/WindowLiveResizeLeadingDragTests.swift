import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDesign
@testable import CmuxNextLayout
import CmuxNextTestSupport
import Testing

/// FRAME OWNER REFACTOR S7, the latency of a live-resize drag. With `motion.frameOwner.liveResize` on, every drag of a
/// window's live resize waited for the window's next frame tick, also a drag that came early in a display frame in which
/// no drag was applied yet: AppKit applied it up to one refresh later than at event time (the switch off). R-HARNESS's
/// clock-corrected judge (3d) on the switch films ab-s7-sw-63b290e (120x2 and 120x1, all four films on clock +1): with
/// the switch on, 64 and 71 frames showed the whole window one refresh late, against 12 and 14 with it off.
///
/// Now the first drag of a display frame goes to AppKit in its own turn, as with the switch off. A drag that comes after
/// one was applied in the same display frame waits for the next frame tick, and the newest of them replaces the rest, so
/// a display frame still applies at most one drag (one `setFrame`, one tree layout). No drag is lost: the newest reaches
/// AppKit at the next tick, or before the release, so the window ends at the pointer. A frame tick with no drag waiting
/// applies nothing. The rig is `WindowLiveResizeFrameTickTests`'s; the test is the clock.
@MainActor
@Suite(.serialized, .closesItsWindows)
struct WindowLiveResizeLeadingDragTests {
    @Test func theFirstDragOfADisplayFrameReachesTheResizeInItsOwnTurn() throws {
        try WindowLiveResizeFrameTickTests.withSwitch(true) {
            let rig = WindowLiveResizeFrameTickTests.Rig()
            defer { rig.close() }
            let window = rig.window, startWidth = window.frame.width
            let press = try rig.pressPoint()
            window.sendEvent(rig.event(.leftMouseDown, press))
            Motion.liveResizeOverride = true
            defer { Motion.liveResizeOverride = nil }

            // The resize's first drag: no drag was applied in this display frame.
            window.sendEvent(rig.event(.leftMouseDragged, CGPoint(x: press.x + 12, y: press.y)))
            #expect(rig.edge.events == [.drag(press.x + 12)], "the first drag of a display frame waited for a frame tick: \(rig.edge.events)")
            #expect(window.frame.width == startWidth + 12, "the window is \(window.frame.width - startWidth) pt wider after the first drag's turn")

            // A frame tick with nothing waiting starts a display frame in which no drag was applied: its first drag goes at once too.
            rig.frameTick()
            window.sendEvent(rig.event(.leftMouseDragged, CGPoint(x: press.x + 24, y: press.y)))
            #expect(rig.edge.events == [.drag(press.x + 12), .drag(press.x + 24)],
                    "the first drag of the next display frame waited for a frame tick: \(rig.edge.events)")
            window.sendEvent(rig.event(.leftMouseUp, CGPoint(x: press.x + 24, y: press.y)))
        }
    }

    @Test func laterDragsOfAFrameWaitAndTheNewestReachesTheResizeAtTheNextTick() throws {
        try WindowLiveResizeFrameTickTests.withSwitch(true) {
            let rig = WindowLiveResizeFrameTickTests.Rig()
            defer { rig.close() }
            let window = rig.window, startWidth = window.frame.width
            let press = try rig.pressPoint()
            window.sendEvent(rig.event(.leftMouseDown, press))
            Motion.liveResizeOverride = true
            defer { Motion.liveResizeOverride = nil }
            func drag(_ dx: CGFloat) { window.sendEvent(rig.event(.leftMouseDragged, CGPoint(x: press.x + dx, y: press.y))) }

            // Three drags in one display frame: the first goes at once, the two after it wait for the frame tick.
            drag(12)
            drag(24)
            drag(36)
            #expect(rig.edge.events == [.drag(press.x + 12)], "a drag after the frame's first reached the resize in its own turn: \(rig.edge.events)")
            #expect(window.frame.width == startWidth + 12, "the window took \(window.frame.width - startWidth) pt in one display frame")

            // The frame tick: the newest drag reaches the resize, the one it replaced never does.
            rig.frameTick()
            #expect(rig.edge.events == [.drag(press.x + 12), .drag(press.x + 36)], "the frame tick gave the resize \(rig.edge.events)")
            #expect(window.frame.width == startWidth + 36, "the window is \(window.frame.width - startWidth) pt wider after the frame tick")

            // That tick applied a drag, so its display frame has one: a drag in it waits for the next tick.
            drag(48)
            #expect(rig.edge.events.count == 2, "a second drag in the display frame of a tick that applied one reached the resize: \(rig.edge.events)")
            rig.frameTick()
            #expect(rig.edge.events.last == .drag(press.x + 48), "the next frame tick gave the resize \(rig.edge.events)")

            // A frame tick with no drag waiting applies nothing: no drag reaches the resize again and the window stays.
            let events = rig.edge.events, width = window.frame.width
            rig.frameTick()
            rig.frameTick()
            #expect(rig.edge.events == events, "a frame tick with no drag waiting gave the resize \(rig.edge.events.dropFirst(events.count))")
            #expect(window.frame.width == width, "a frame tick with no drag waiting resized the window by \(window.frame.width - width) pt")

            // A release while a drag waits: that drag reaches the resize first, then the release; the window ends at the pointer.
            drag(60)
            drag(72)
            #expect(rig.edge.events.last == .drag(press.x + 60), "the first drag after an idle tick waited: \(rig.edge.events)")
            window.sendEvent(rig.event(.leftMouseUp, CGPoint(x: press.x + 72, y: press.y)))
            #expect(Array(rig.edge.events.suffix(3)) == [.drag(press.x + 60), .drag(press.x + 72), .up], "the resize got \(rig.edge.events)")
            #expect(window.frame.width == startWidth + 72, "the window ended \(window.frame.width - startWidth) pt wider, the pointer 72 pt")
        }
    }
}
