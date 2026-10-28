import AppKit
@testable import CmuxNextFloating
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Foundation
import Testing

/// The pet's drag on frame-aligned input (feature `pointerFrameDrags`): the panel moves on a
/// frame interval's first drag event and once more at the frame, to the latest point (Chromium's rAF-aligned
/// moves), at each event's own screen point; the release lands the pending point before the drop.
@MainActor @Suite(.serialized) struct ChiefPetDragFramesTests {
    final class Harness {
        let frames = FrameInputTestRig()
        let defaults: UserDefaults
        let suite = "ChiefPetDragFramesTests.\(UUID().uuidString)"
        let panel: ChiefPetPanel
        var ended = 0
        var moves = 0
        let down: CGPoint

        init() throws {
            defaults = try #require(UserDefaults(suiteName: suite))
            panel = ChiefPetPanel(defaults: defaults, pointerFrames: frames.coalescers)
            panel.setFrameOrigin(CGPoint(x: 200, y: 200))
            panel.pet.layoutSubtreeIfNeeded()
            let spot = panel.pet.convert(CGPoint(x: panel.pet.characterFrame.midX, y: panel.pet.characterFrame.midY), to: nil)
            down = panel.convertPoint(toScreen: spot)
            panel.pet.onDragEnded = { [unowned self] in ended += 1 }
            panel.pet.onDragMoved = { [unowned self] in moves += 1 }
        }

        /// The press, then a drag by `offset` from it.
        func press() { panel.pet.mouseDown(with: Self.event(.leftMouseDown, at: down)) }
        func drag(by offset: CGVector) {
            panel.pet.mouseDragged(with: Self.event(.leftMouseDragged, at: CGPoint(x: down.x + offset.dx, y: down.y + offset.dy)))
        }
        func release(at offset: CGVector) {
            panel.pet.mouseUp(with: Self.event(.leftMouseUp, at: CGPoint(x: down.x + offset.dx, y: down.y + offset.dy)))
        }

        func tearDown() {
            frames.close()
            panel.orderOut(nil)
            defaults.removePersistentDomain(forName: suite)
        }

        /// A mouse event at `point` on screen. It has no window, so its location is that screen point.
        static func event(_ type: NSEvent.EventType, at point: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
    }

    @Test func eightDragsInOneFrameMoveThePanelTwice() throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        harness.press()
        harness.drag(by: CGVector(dx: 20, dy: -10))
        #expect(harness.panel.frame.origin == CGPoint(x: 220, y: 190), "the frame's first drag moves it at once")

        for step in 1...7 { harness.drag(by: CGVector(dx: 20 + 10 * Double(step), dy: -10)) }
        #expect(harness.panel.frame.origin == CGPoint(x: 220, y: 190), "later drags wait for the frame")
        #expect(harness.moves == 1)

        harness.frames.frame()
        #expect(harness.panel.frame.origin == CGPoint(x: 290, y: 190), "the frame moves it to the latest point")
        #expect(harness.moves == 2)
        #expect((harness.panel.pet.frameDrag?.maxDeliveriesPerFrame ?? 0) <= 2)
    }

    @Test func theReleaseLandsThePendingPointBeforeTheDrop() throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        harness.press()
        harness.drag(by: CGVector(dx: 30, dy: 0))
        harness.drag(by: CGVector(dx: 60, dy: -30))
        var originAtDrop: CGPoint?
        harness.panel.pet.onDragEnded = { [panel = harness.panel] in originAtDrop = panel.frame.origin }
        harness.release(at: CGVector(dx: 60, dy: -30))

        #expect(originAtDrop == CGPoint(x: 260, y: 170), "the drop sees the drag's last point")
        #expect(!harness.frames.coalescer.hasPending)
        #expect(harness.panel.pet.frameDrag == nil)
    }

    /// A press that never passes the slop stays a click, with or without frames.
    @Test func aPressWithinTheSlopIsStillAClick() throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        var clicks = 0
        harness.panel.pet.onClick = { clicks += 1 }
        harness.press()
        harness.drag(by: CGVector(dx: 1, dy: 0))
        harness.release(at: CGVector(dx: 1, dy: 0))

        #expect(clicks == 1)
        #expect(harness.ended == 0)
        #expect(harness.panel.frame.origin == CGPoint(x: 200, y: 200))
    }
}
