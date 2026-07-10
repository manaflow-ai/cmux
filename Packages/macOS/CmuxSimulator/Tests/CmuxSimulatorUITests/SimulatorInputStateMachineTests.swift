import CmuxSimulator
import Foundation
import Testing
@testable import CmuxSimulatorUI

@Suite("Simulator input state machine")
struct SimulatorInputStateMachineTests {
    @Test("Touch events preserve order and mirror Option pinch")
    func touchOrderingAndPinch() {
        var input = SimulatorInputStateMachine()
        let start = SimulatorPoint(x: 0.2, y: 0.3)
        let end = SimulatorPoint(x: 0.4, y: 0.6)

        let messages = input.pointerBegan(at: start, optionPinch: true)
            + input.pointerMoved(to: end)
            + input.pointerEnded(at: end)

        #expect(messages == [
            .pointer(SimulatorPointerEvent(
                phase: .began,
                primary: start,
                secondary: SimulatorPoint(x: 0.8, y: 0.7)
            )),
            .pointer(SimulatorPointerEvent(
                phase: .moved,
                primary: end,
                secondary: SimulatorPoint(x: 0.6, y: 0.4)
            )),
            .pointer(SimulatorPointerEvent(
                phase: .ended,
                primary: end,
                secondary: SimulatorPoint(x: 0.6, y: 0.4)
            )),
        ])
    }

    @Test("Option Shift drag keeps the second touch at a fixed offset")
    func parallelTwoFingerPan() {
        var input = SimulatorInputStateMachine()
        let start = SimulatorPoint(x: 0.25, y: 0.25)
        let moved = SimulatorPoint(x: 0.5, y: 0.5)

        let messages = input.pointerBegan(
            at: start,
            optionPinch: true,
            parallelPan: true
        ) + input.pointerMoved(to: moved)

        #expect(messages == [
            .pointer(SimulatorPointerEvent(
                phase: .began,
                primary: start,
                secondary: SimulatorPoint(x: 0.75, y: 0.75)
            )),
            .pointer(SimulatorPointerEvent(
                phase: .moved,
                primary: moved,
                secondary: SimulatorPoint(x: 1, y: 1)
            )),
        ])
    }

    @Test("Focus cleanup cancels touch, releases keys, and resets worker state")
    func focusCleanup() {
        var input = SimulatorInputStateMachine()
        _ = input.pointerBegan(at: SimulatorPoint(x: 0.5, y: 0.5), optionPinch: false)
        _ = input.key(usage: 0xE1, phase: .down)
        _ = input.key(usage: 0x04, phase: .down)

        let messages = input.releaseAll()

        #expect(messages == [
            .pointer(SimulatorPointerEvent(
                phase: .cancelled,
                primary: SimulatorPoint(x: 0.5, y: 0.5)
            )),
            .key(SimulatorKeyEvent(usage: 0x04, phase: .up)),
            .key(SimulatorKeyEvent(usage: 0xE1, phase: .up)),
            .releaseInputs,
        ])
        #expect(input.activePointer == nil)
        #expect(input.heldKeys.isEmpty)
    }

    @Test("Continuous scroll becomes one ordered touch sequence")
    func continuousScrollOrdering() {
        var input = SimulatorInputStateMachine()

        let messages = input.scroll(deltaX: 0, deltaY: 30, phase: .began)
            + input.scroll(deltaX: 0, deltaY: 30, phase: .changed)
            + input.scroll(deltaX: 0, deltaY: 0, phase: .ended)

        #expect(pointerPhases(in: messages) == [.began, .moved, .moved, .ended])
    }

    @Test("Scroll begins under the pointer anchor")
    func scrollUsesPointerAnchor() {
        var input = SimulatorInputStateMachine()
        let anchor = SimulatorPoint(x: 0.15, y: 0.8)

        let messages = input.scroll(
            deltaX: 0,
            deltaY: 30,
            phase: .began,
            anchor: anchor
        )

        #expect(messages.first == .pointer(SimulatorPointerEvent(
            phase: .began,
            primary: anchor
        )))
    }

    @Test("Starting a touch cancels scrolling and scrolling cannot overlap the touch")
    func touchAndScrollAreExclusive() {
        var input = SimulatorInputStateMachine()
        let scroll = input.scroll(deltaX: 0, deltaY: 30, phase: .began)
        let scrollPoint = try? #require(scroll.compactMap { message -> SimulatorPoint? in
            guard case let .pointer(event) = message, event.phase == .moved else { return nil }
            return event.primary
        }.last)
        let touch = SimulatorPoint(x: 0.2, y: 0.3)

        let began = input.pointerBegan(at: touch, optionPinch: false)

        #expect(began.first == scrollPoint.map {
            .pointer(SimulatorPointerEvent(phase: .cancelled, primary: $0))
        })
        #expect(began.last == .pointer(SimulatorPointerEvent(phase: .began, primary: touch)))
        #expect(input.scroll(deltaX: 0, deltaY: 30, phase: .changed).isEmpty)
    }

    @Test("Long continuous scrolls re-anchor before reaching an edge")
    func continuousScrollReanchors() {
        var input = SimulatorInputStateMachine()
        var messages = input.scroll(deltaX: 10_000, deltaY: 10_000, phase: .began)
        for _ in 0..<10 {
            messages += input.scroll(deltaX: 10_000, deltaY: 10_000, phase: .changed)
        }

        let points = messages.compactMap { message -> SimulatorPoint? in
            guard case let .pointer(event) = message else { return nil }
            return event.primary
        }
        #expect(points.allSatisfy { (0.08...0.92).contains($0.x) && (0.08...0.92).contains($0.y) })
        #expect(pointerPhases(in: messages).filter { $0 == .began }.count > 1)
    }

    @Test("Display edges are classified for system gestures")
    func edgeClassification() {
        #expect(SimulatorInputStateMachine.edge(at: SimulatorPoint(x: 0, y: 0.5)) == .left)
        #expect(SimulatorInputStateMachine.edge(at: SimulatorPoint(x: 1, y: 0.5)) == .right)
        #expect(SimulatorInputStateMachine.edge(at: SimulatorPoint(x: 0.5, y: 0)) == .top)
        #expect(SimulatorInputStateMachine.edge(at: SimulatorPoint(x: 0.5, y: 1)) == .bottom)
        #expect(SimulatorInputStateMachine.edge(at: SimulatorPoint(x: 0.5, y: 0.5)) == .none)
    }

    @Test("Raw portrait landscape input maps touches, pinch, edges, and scroll movement")
    func rawPortraitLandscapeInput() {
        var input = SimulatorInputStateMachine()
        input.updateOrientationGeometry(SimulatorOrientationGeometry(
            rawWidth: 400,
            rawHeight: 800,
            requestedOrientation: .landscapeLeft
        ))

        let touch = input.pointerBegan(
            at: SimulatorPoint(x: 0.5, y: 1),
            optionPinch: true
        )
        _ = input.pointerEnded(at: SimulatorPoint(x: 0.5, y: 1))
        let scroll = input.scroll(deltaX: 60, deltaY: 0, phase: .began)

        #expect(touch == [.pointer(SimulatorPointerEvent(
            phase: .began,
            primary: SimulatorPoint(x: 1, y: 0.5),
            secondary: SimulatorPoint(x: 0, y: 0.5),
            edge: .right
        ))])
        #expect(scroll == [
            .pointer(SimulatorPointerEvent(
                phase: .began,
                primary: SimulatorPoint(x: 0.5, y: 0.5)
            )),
            .pointer(SimulatorPointerEvent(
                phase: .moved,
                primary: SimulatorPoint(x: 0.5, y: 0.6)
            )),
        ])
    }

    @Test("Drag coordinates clamp to the live display opening")
    @MainActor
    func dragCoordinatesClamp() {
        let rect = CGRect(x: 20, y: 30, width: 400, height: 800)

        let point = SimulatorRemoteSurfaceView.normalizedPoint(
            location: CGPoint(x: -100, y: 1_000),
            displayRect: rect,
            clamped: true
        )

        #expect(point == SimulatorPoint(x: 0, y: 0))
        #expect(SimulatorRemoteSurfaceView.normalizedPoint(
            location: CGPoint(x: -100, y: 1_000),
            displayRect: rect,
            clamped: false
        ) == nil)
    }

    private func pointerPhases(in messages: [SimulatorWorkerInbound]) -> [SimulatorTouchPhase] {
        messages.compactMap { message in
            guard case let .pointer(event) = message else { return nil }
            return event.phase
        }
    }
}
