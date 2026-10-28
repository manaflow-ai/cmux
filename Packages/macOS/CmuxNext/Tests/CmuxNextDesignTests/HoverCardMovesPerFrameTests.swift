import AppKit
@testable import CmuxNextDesign
import CmuxNextDesignTokens
import CmuxNextInput
import CmuxNextWakeupsTestSupport
import Testing

/// A shown hover card's pointer moves (`cardMoves`) reach it on its parent window's frame (feature
/// `pointerFrameHover`), as Chromium delivers rAF-aligned moves
/// (`third_party/blink/renderer/platform/widget/input/main_thread_event_queue.cc`): the first move of a
/// frame interval in its own turn, the rest once at the frame, at the latest point. Leaving the card
/// still hides it, on the frame's delivery at the latest.
@MainActor @Suite(.serialized) struct HoverCardMovesPerFrameTests {
    private final class Source: HoverCardSource {
        let window: NSWindow
        let body: NSView
        init(window: NSWindow) {
            self.window = window
            body = NSView()
            body.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                body.widthAnchor.constraint(equalToConstant: 240),
                body.heightAnchor.constraint(equalToConstant: 90),
            ])
        }
        var hoverCardWindow: NSWindow? { window }
        func hoverCardHit(at screenPoint: CGPoint) -> HoverCardHit? {
            guard window.frame.contains(screenPoint) else { return nil }
            // No delay: a moving pointer shows the card on this move; it hides as the pointer leaves for anywhere but the card.
            let target = HoverTarget(id: HoverTargetID("tab"), window: window.windowNumber, delay: .zero,
                                     leave: .hides(reshow: .milliseconds(300)))
            return HoverCardHit(target: target, anchor: window.frame)
        }
        func hoverCardAnchor(for id: HoverTargetID) -> CGRect? { window.frame }
        func hoverCardBody(for id: HoverTargetID) -> HoverCardBody? {
            HoverCardBody(view: body, placement: .below, themeAnchor: nil, applyTheme: {})
        }
        func hoverCardActivated(_ id: HoverTargetID) {}
        func hoverCardDeactivated(_ id: HoverTargetID) {}
    }

    @MainActor private final class Rig {
        let events: InputTapTestEvents
        let frames: PointerFrameTestRig
        let window: HoverFramesTestWindow
        let source: Source
        let coordinator: HoverCardCoordinator
        let card: CGRect

        /// A card shown for the window's one target, its moves on the window's frames (`frameInput`) or not.
        init(frameInput: Bool = true) throws {
            Motion.reduceMotionOverride = true
            let events = InputTapTestEvents()
            let frames = PointerFrameTestRig()
            let window = HoverFramesTestWindow.make(frames: frameInput ? frames.coalescers : nil)
            let source = Source(window: window)
            let coordinator = HoverCardCoordinator(clock: ManualClock(), input: events.tap)
            coordinator.register(source)
            let frame = window.frame
            coordinator.pointerLocation = { CGPoint(x: frame.midX, y: frame.midY) }
            coordinator.appIsActive = { true }
            coordinator.hoverCardsEnabled = { true }
            coordinator.mouseButtonDown = { false }
            coordinator.windowNumberAt = { _ in window.windowNumber }
            coordinator.ownWindows = { [(number: window.windowNumber, frame: frame)] }
            coordinator.pointerMoved()
            self.events = events
            self.frames = frames
            self.window = window
            self.source = source
            self.coordinator = coordinator
            card = try #require(coordinator.shownCardFrame, "no card shows: \(coordinator.machine.phase)")
        }

        /// A screen point on the card, and one off the card and off the window.
        var onCard: CGPoint { CGPoint(x: card.midX, y: card.midY) }
        var away: CGPoint { CGPoint(x: window.frame.maxX + 400, y: window.frame.maxY + 400) }

        /// A move seen by the tap at `screenPoint`.
        func move(to screenPoint: CGPoint) throws {
            events.dispatch(try InputTapTestEvents.mouse(.mouseMoved, at: window.convertPoint(fromScreen: screenPoint), in: window))
        }

        func close() {
            coordinator.dismiss(.action)
            coordinator.unregister(source)
            frames.close()
            window.orderOut(nil)
            Motion.reduceMotionOverride = nil
        }
    }

    /// Eight moves in one frame, seven on the card and the last off it: the card checks the leading move
    /// at once and the latest at the frame, two checks, and the frame's check hides the card.
    @Test func eightMovesOnACardInOneFrameCheckTwiceAndTheLastOneOffHidesIt() throws {
        let rig = try Rig()
        defer { rig.close() }
        let before = rig.coordinator.cardMoveChecks
        for step in 0..<8 { try rig.move(to: step == 7 ? rig.away : rig.onCard) }
        #expect(rig.coordinator.cardMoveChecks - before == 1, "a move after the leading one reached the card before the frame")
        #expect(rig.coordinator.machine.shownTarget != nil, "the card hid before the move off it landed")
        let moves = try #require(rig.coordinator.cardMoveFrames, "the card's moves are not on its parent's frames")
        #expect(moves.hasPending)
        rig.frames.frame()
        #expect(rig.coordinator.cardMoveChecks - before == 2)
        #expect(moves.maxDeliveriesPerFrame == 2)
        #expect(rig.coordinator.machine.shownTarget == nil, "the card stayed after the pointer left it (\(rig.coordinator.machine.phase))")
    }

    /// After a frame, the first move off the card is a frame interval's leading move: it hides the card in its own turn.
    @Test func theFirstMoveOffTheCardAfterAFrameHidesItAtOnce() throws {
        let rig = try Rig()
        defer { rig.close() }
        try rig.move(to: rig.onCard)
        try rig.move(to: rig.onCard)
        rig.frames.frame()
        #expect(rig.coordinator.machine.shownTarget != nil, "a move on the card hid it")
        try rig.move(to: rig.away)
        #expect(rig.coordinator.machine.shownTarget == nil, "the move off the card waited (\(rig.coordinator.machine.phase))")
    }

    /// A parent that carries no frames (the feature off): every move reaches the card in its own turn.
    @Test func withoutTheParentsFramesEachMoveReachesTheCard() throws {
        let rig = try Rig(frameInput: false)
        defer { rig.close() }
        let before = rig.coordinator.cardMoveChecks
        for _ in 0..<8 { try rig.move(to: rig.onCard) }
        #expect(rig.coordinator.cardMoveChecks - before == 8)
        #expect(rig.coordinator.cardMoveFrames == nil)
    }
}
