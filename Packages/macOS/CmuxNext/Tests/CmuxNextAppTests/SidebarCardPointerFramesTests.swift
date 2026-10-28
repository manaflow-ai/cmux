import AppKit
@testable import CmuxNextSidebar
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Foundation
import Testing

/// The sidebar cards' per-event pointer sites on frame-aligned input: the Now Playing
/// scrubber's drag (`pointerFrameDrags`) and the Update Ready card's moves (`pointerFrameHover`) act on a
/// frame interval's first event and once more at the frame, at the latest point, as Chromium delivers
/// rAF-aligned moves; a press or a release lands the pending point first.
@MainActor @Suite(.serialized) struct SidebarCardPointerFramesTests {
    static let labels = SidebarNowPlaying.Labels(play: "Play", pause: "Pause", previous: "Previous Track", next: "Next Track")

    final class Harness {
        let frames = FrameInputTestRig()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.borderless],
                              backing: .buffered, defer: false)

        init() {
            _ = NSApplication.shared
            window.isReleasedWhenClosed = false
        }

        func event(_ type: NSEvent.EventType, x: Double, y: Double = 6) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: CGPoint(x: x, y: y), modifierFlags: [],
                                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                            context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
        }

        func tearDown() {
            frames.close()
            window.close()
        }
    }

    /// A paused 100 s track on a 100 pt scrubber at the window's left edge: one point is one second.
    static func scrubber(in harness: Harness, frames: Bool = true) -> SidebarNowPlayingScrubber {
        let scrubber = SidebarNowPlayingScrubber(frame: NSRect(x: 0, y: 0, width: 100, height: SidebarNowPlayingScrubber.height))
        harness.window.contentView?.addSubview(scrubber)
        scrubber.reduceMotionOverride = true
        scrubber.show(SidebarNowPlaying(title: "Track", isPlaying: false, position: 0, duration: 100, labels: labels))
        if frames { scrubber.pointerFrames = harness.frames.coalescers }
        return scrubber
    }

    @Test func eightScrubDragsInOneFrameMoveThePositionTwice() throws {
        let harness = Harness()
        defer { harness.tearDown() }
        let scrubber = Self.scrubber(in: harness)
        var seeks: [TimeInterval] = []
        scrubber.onSeek = { seeks.append($0) }

        scrubber.mouseDown(with: try harness.event(.leftMouseDown, x: 10))
        scrubber.mouseDragged(with: try harness.event(.leftMouseDragged, x: 20))
        #expect(scrubber.dragged == 20, "the frame's first drag scrubs at once")
        for x in stride(from: 30.0, through: 90.0, by: 10) { scrubber.mouseDragged(with: try harness.event(.leftMouseDragged, x: x)) }
        #expect(scrubber.dragged == 20, "later drags wait for the frame")

        harness.frames.frame()
        #expect(scrubber.dragged == 90, "the frame scrubs to the latest point")
        #expect((scrubber.frameDrag?.maxDeliveriesPerFrame ?? 0) <= 2)

        scrubber.mouseUp(with: try harness.event(.leftMouseUp, x: 90))
        #expect(seeks == [90])
        #expect(scrubber.frameDrag == nil)
    }

    @Test func theScrubReleaseLandsThePendingPointFirst() throws {
        let harness = Harness()
        defer { harness.tearDown() }
        let scrubber = Self.scrubber(in: harness)
        var shownAtSeek: TimeInterval?
        scrubber.onSeek = { [unowned scrubber] _ in shownAtSeek = scrubber.dragged }

        scrubber.mouseDown(with: try harness.event(.leftMouseDown, x: 10))
        scrubber.mouseDragged(with: try harness.event(.leftMouseDragged, x: 30))
        scrubber.mouseDragged(with: try harness.event(.leftMouseDragged, x: 70))
        scrubber.mouseUp(with: try harness.event(.leftMouseUp, x: 70))

        #expect(shownAtSeek == 70)
        #expect(!harness.frames.coalescer.hasPending)
    }

    @Test func withoutFramesEveryScrubDragMoves() throws {
        let harness = Harness()
        defer { harness.tearDown() }
        let scrubber = Self.scrubber(in: harness, frames: false)
        scrubber.mouseDown(with: try harness.event(.leftMouseDown, x: 10))
        scrubber.mouseDragged(with: try harness.event(.leftMouseDragged, x: 20))
        scrubber.mouseDragged(with: try harness.event(.leftMouseDragged, x: 40))
        #expect(scrubber.dragged == 40)
    }

    @Test func eightCardMovesInOneFrameAskTheHoverOwnerTwice() throws {
        let harness = Harness()
        defer { harness.tearDown() }
        let card = SidebarUpdateCardView(frame: NSRect(x: 0, y: 0, width: 200, height: 120))
        harness.window.contentView?.addSubview(card)
        card.moves.frames = harness.frames.coalescers

        for x in stride(from: 10.0, through: 80.0, by: 10) { card.mouseMoved(with: try harness.event(.mouseMoved, x: x, y: 40)) }
        #expect(card.moves.hasPending, "the moves after the frame's first wait for the frame")
        #expect(card.moves.maxDeliveriesPerFrame == 1)

        harness.frames.frame()
        #expect(!card.moves.hasPending)
        #expect(card.moves.maxDeliveriesPerFrame == 2)
    }

    @Test func aPressOnTheCardLandsItsPendingMoveFirst() throws {
        let harness = Harness()
        defer { harness.tearDown() }
        let card = SidebarUpdateCardView(frame: NSRect(x: 0, y: 0, width: 200, height: 120))
        harness.window.contentView?.addSubview(card)
        card.moves.frames = harness.frames.coalescers

        card.mouseMoved(with: try harness.event(.mouseMoved, x: 10, y: 40))
        card.mouseMoved(with: try harness.event(.mouseMoved, x: 20, y: 40))
        #expect(card.moves.hasPending)
        card.mouseDown(with: try harness.event(.leftMouseDown, x: 20, y: 40))
        #expect(!card.moves.hasPending)
        card.mouseUp(with: try harness.event(.leftMouseUp, x: 250, y: 190))
    }
}
