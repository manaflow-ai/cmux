#if os(iOS)
import QuartzCore
import SwiftUI
import UIKit

/// One pinch sample in the tabs screen's coordinate space.
struct PinchSample: Equatable {
    enum Phase: Equatable { case began, changed, ended }
    var phase: Phase
    /// Finger distance relative to the gesture's start.
    var scale: CGFloat
    /// Midpoint between the fingers.
    var centroid: CGPoint
    var time: CFTimeInterval
}

/// A UIKit pinch recognizer attached to the whole tabs screen. It never
/// cancels or delays touches, so the page and the grid's scroll view keep
/// getting theirs; the screen decides per gesture whether
/// the pinch drives the tab zoom.
struct ZoomPinchGesture: UIGestureRecognizerRepresentable {
    var onSample: (PinchSample) -> Void

    func makeUIGestureRecognizer(context: Context) -> UIPinchGestureRecognizer {
        let g = UIPinchGestureRecognizer()
        g.cancelsTouchesInView = false
        g.delaysTouchesBegan = false
        g.delaysTouchesEnded = false
        g.delegate = context.coordinator
        return g
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func handleUIGestureRecognizerAction(_ g: UIPinchGestureRecognizer, context: Context) {
        let phase: PinchSample.Phase
        switch g.state {
        case .began: phase = .began
        case .changed: phase = .changed
        case .ended, .cancelled, .failed: phase = .ended
        default: return
        }
        let c = context.converter.location(in: .named(TabsScreenSpace.name))
        onSample(PinchSample(phase: phase, scale: g.scale, centroid: c, time: CACurrentMediaTime()))
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }
}

/// Bookkeeping for one pinch (reference type: updates must not re-render).
@MainActor
final class ZoomPinchSession {
    enum Decision { case pending, engaged, rejected }
    /// Pinch-in past this (relative scale) drives the zoom.
    static let engageIn: CGFloat = 0.96
    /// Pinch-out on a grid card past this opens it.
    static let engageOut: CGFloat = 1.04
    /// The decision window from the gesture's start.
    static let decisionWindow: CFTimeInterval = 0.04

    var decision: Decision = .pending
    var start: PinchSample?
    /// When the finger distance first changed (the decision window starts here).
    var movementStart: CFTimeInterval?
    var startRect: CGRect = .zero
    var startedFromOverview = false
    var tracker: PinchTracker?
    /// Recent (time, progress, offset) for the release velocity.
    var history: [(t: CFTimeInterval, p: Double, o: CGVector)] = []

    func reset() {
        decision = .pending
        start = nil
        movementStart = nil
        tracker = nil
        history = []
    }

    func record(_ t: CFTimeInterval, _ p: Double, _ o: CGVector) {
        history.append((t, p, o))
        if history.count > 12 { history.removeFirst(history.count - 12) }
    }

    /// Velocity over the last ~40 ms of samples (a window, not a filter on
    /// the tracked position: the rect itself follows the latest sample).
    func velocity() -> (p: Double, o: CGVector) {
        guard let last = history.last else { return (0, .zero) }
        let ref = history.last { last.t - $0.t >= 0.04 } ?? history.first!
        let dt = last.t - ref.t
        guard dt > 0.004 else { return (0, .zero) }
        return ((last.p - ref.p) / dt, CGVector(dx: (last.o.dx - ref.o.dx) / dt, dy: (last.o.dy - ref.o.dy) / dt))
    }
}
#endif
