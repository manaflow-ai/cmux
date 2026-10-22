import CoreGraphics
import Testing
@testable import CmuxNextPhone

/// Two-finger scrolling over the phone drags its screen, like a finger (classic cmux parity).
@Suite struct PhoneScrollGestureTests {
    let screen = CGSize(width: 400, height: 800)

    @Test func aTrackpadScrollIsOneFingerDrag() {
        var gesture = PhoneScrollGesture()
        let start = gesture.touches(.began, at: CGPoint(x: 0.5, y: 0.5), delta: .zero, screen: screen)
        let move = gesture.touches(.changed, at: CGPoint(x: 0.5, y: 0.5), delta: CGVector(dx: 100, dy: 200), screen: screen)
        let end = gesture.touches(.ended, at: CGPoint(x: 0.9, y: 0.9), delta: .zero, screen: screen)
        #expect(start.map { $0.0 } == [.began] && start.map { $0.1 } == [CGPoint(x: 0.5, y: 0.5)])
        #expect(move.map { $0.0 } == [.moved] && move.map { $0.1 } == [CGPoint(x: 0.75, y: 0.75)])
        #expect(end.map { $0.0 } == [.ended] && end.map { $0.1 } == [CGPoint(x: 0.75, y: 0.75)], "the finger lifts where the drag reached")
    }

    @Test func theDragStaysOnTheScreen() {
        var gesture = PhoneScrollGesture()
        _ = gesture.touches(.began, at: CGPoint(x: 0.5, y: 0.9), delta: .zero, screen: screen)
        let move = gesture.touches(.changed, at: .zero, delta: CGVector(dx: 0, dy: 1000), screen: screen)
        #expect(move.first.map { $0.1.y } == 1)
    }

    @Test func aMouseWheelTickIsAShortDragAndChangesWithoutABeginDoNothing() {
        var gesture = PhoneScrollGesture()
        #expect(gesture.touches(.changed, at: CGPoint(x: 0.5, y: 0.5), delta: CGVector(dx: 0, dy: 10), screen: screen).isEmpty)
        let tick = gesture.touches(.wheel, at: CGPoint(x: 0.5, y: 0.5), delta: CGVector(dx: 0, dy: -20), screen: screen)
        #expect(tick.map { $0.0 } == [.began, .moved, .ended])
        #expect(tick.last.map { $0.1 } == CGPoint(x: 0.5, y: 0.25))
    }
}
