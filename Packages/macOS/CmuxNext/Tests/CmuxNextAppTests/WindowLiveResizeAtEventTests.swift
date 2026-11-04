import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDesign
@testable import CmuxNextLayout
import CmuxNextTestSupport
import Testing

/// FRAME OWNER REFACTOR S7 diagnostic `motion.frameOwner.liveResize.atEvent`: a live resize coalesces its drags at input.
/// A drag with a newer one already queued waits for it; the newer one goes to AppKit in its own event turn with the
/// waiting one's travel. Nothing goes on the frame tick. The queue peek is replaced so the test is the queue.
@MainActor
@Suite(.serialized, .closesItsWindows)
struct WindowLiveResizeAtEventTests {
    @Test func aDragGoesInItsOwnTurnUnlessANewerOneIsQueued() throws {
        try WindowLiveResizeFrameTickTests.withSwitch(true) {
            TunableStore.shared.set("motion.frameOwner.liveResize.atEvent", .bool(true))
            defer { TunableStore.shared.set("motion.frameOwner.liveResize.atEvent", nil) }
            let rig = WindowLiveResizeFrameTickTests.Rig()
            defer { rig.close() }
            let window = rig.window, startWidth = window.frame.width
            var queued = false
            window.liveResizeInput.newerDragQueued = { queued }
            let press = try rig.pressPoint()
            window.sendEvent(rig.event(.leftMouseDown, press))
            Motion.liveResizeOverride = true
            defer { Motion.liveResizeOverride = nil }

            // A newer drag is queued: this one waits for it.
            queued = true
            window.sendEvent(rig.event(.leftMouseDragged, CGPoint(x: press.x + 12, y: press.y)))
            #expect(rig.edge.events.isEmpty, "a drag with a newer one queued reached the resize: \(rig.edge.events)")
            // The newer one, with nothing after it: it goes in its own turn.
            queued = false
            window.sendEvent(rig.event(.leftMouseDragged, CGPoint(x: press.x + 24, y: press.y)))
            #expect(rig.edge.events == [.drag(press.x + 24)], "the resize got \(rig.edge.events)")
            #expect(window.frame.width == startWidth + 24, "the window is \(window.frame.width - startWidth) pt wider")
            // Nothing waits for a frame tick.
            rig.frameTick()
            #expect(rig.edge.events == [.drag(press.x + 24)], "a frame tick gave the resize \(rig.edge.events)")
            window.sendEvent(rig.event(.leftMouseUp, CGPoint(x: press.x + 24, y: press.y)))
            #expect(rig.edge.events.last == .up)
        }
    }
}
