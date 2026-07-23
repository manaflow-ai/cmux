public import CoreGraphics

/// Pure lifecycle for a press that may become a local sidebar reorder.
///
/// Architecture invariant: one owner handles the pointer from press until it
/// either finishes locally or hands off once to AppKit's system drag. Local
/// reorder and system drag must never consume the same movement concurrently.
/// Keeping that invariant in a value type makes the AppKit adapter a renderer
/// of explicit effects instead of a second source of gesture state.
public struct SidebarWorkspaceDirectReorderGesture: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case pressed
        case reordering
        case handedOff
        case finished
        case cancelled
    }

    public enum Effect: Equatable, Sendable {
        case none
        case click
        case beginReorder(at: CGPoint)
        case updateReorder(at: CGPoint)
        case commitReorder(at: CGPoint)
        case cancelReorder
        case handoffToSystemDrag(at: CGPoint)
    }

    public private(set) var phase: Phase = .pressed

    private let origin: CGPoint
    private let systemHandoffBounds: CGRect
    private let dragThresholdSquared: CGFloat

    public init(
        origin: CGPoint,
        windowBounds: CGRect,
        dragThreshold: CGFloat,
        systemHandoffMargin: CGFloat
    ) {
        self.origin = origin
        let threshold = max(0, dragThreshold)
        dragThresholdSquared = threshold * threshold
        let margin = max(0, systemHandoffMargin)
        systemHandoffBounds = windowBounds.insetBy(dx: -margin, dy: -margin)
    }

    public mutating func drag(to point: CGPoint) -> Effect {
        switch phase {
        case .pressed:
            let deltaX = point.x - origin.x
            let deltaY = point.y - origin.y
            guard deltaX * deltaX + deltaY * deltaY >= dragThresholdSquared else {
                return .none
            }
            guard systemHandoffBounds.contains(point) else {
                phase = .handedOff
                return .handoffToSystemDrag(at: point)
            }
            phase = .reordering
            return .beginReorder(at: point)
        case .reordering:
            guard systemHandoffBounds.contains(point) else {
                phase = .handedOff
                return .handoffToSystemDrag(at: point)
            }
            return .updateReorder(at: point)
        case .handedOff, .finished, .cancelled:
            return .none
        }
    }

    public mutating func release(at point: CGPoint) -> Effect {
        switch phase {
        case .pressed:
            phase = .finished
            return .click
        case .reordering:
            phase = .finished
            return .commitReorder(at: point)
        case .handedOff, .finished, .cancelled:
            return .none
        }
    }

    public mutating func cancel() -> Effect {
        switch phase {
        case .reordering:
            phase = .cancelled
            return .cancelReorder
        case .pressed:
            phase = .cancelled
            return .none
        case .handedOff, .finished, .cancelled:
            return .none
        }
    }
}
