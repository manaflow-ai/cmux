import AppKit
import OwlMojoBindingsGenerated

private let owlWheelPixelsPerTick: CGFloat = 40
private let owlWheelPrecisePixelDeltaUnits: UInt32 = 0
private let owlWheelPixelDeltaUnits: UInt32 = 1

@MainActor
struct OwlInputEventBridge {
    func mouseEvent(
        from event: NSEvent,
        in view: NSView,
        kind: OwlFreshMouseKind,
        button: UInt32,
        clickCount: UInt32
    ) -> OwlFreshMouseEvent {
        let point = browserPoint(for: event, in: view)
        return OwlFreshMouseEvent(
            kind: kind,
            x: Float(point.x),
            y: Float(point.y),
            button: button,
            clickCount: clickCount,
            deltaX: 0,
            deltaY: 0,
            modifiers: event.owlModifiers
        )
    }

    func wheelEvent(from event: NSEvent, in view: NSView) -> OwlFreshWheelEvent {
        let point = browserPoint(for: event, in: view)
        return OwlFreshWheelEvent(
            x: Float(point.x),
            y: Float(point.y),
            deltaX: Float(event.owlWheelDeltaX),
            deltaY: Float(event.owlWheelDeltaY),
            wheelTicksX: Float(event.owlWheelTicksX),
            wheelTicksY: Float(event.owlWheelTicksY),
            phase: UInt32(truncatingIfNeeded: event.phase.rawValue),
            momentumPhase: UInt32(truncatingIfNeeded: event.momentumPhase.rawValue),
            modifiers: event.owlModifiers,
            deltaUnits: event.hasPreciseScrollingDeltas ? owlWheelPrecisePixelDeltaUnits : owlWheelPixelDeltaUnits
        )
    }

    func browserPoint(for event: NSEvent, in view: NSView) -> CGPoint {
        let point = view.convert(event.locationInWindow, from: nil)
        return CGPoint(x: point.x, y: view.bounds.height - point.y)
    }
}

private extension NSEvent {
    var owlWheelDeltaX: CGFloat {
        hasPreciseScrollingDeltas ? scrollingDeltaX : deltaX * owlWheelPixelsPerTick
    }

    var owlWheelDeltaY: CGFloat {
        hasPreciseScrollingDeltas ? scrollingDeltaY : deltaY * owlWheelPixelsPerTick
    }

    var owlWheelTicksX: CGFloat {
        hasPreciseScrollingDeltas ? scrollingDeltaX / owlWheelPixelsPerTick : deltaX
    }

    var owlWheelTicksY: CGFloat {
        hasPreciseScrollingDeltas ? scrollingDeltaY / owlWheelPixelsPerTick : deltaY
    }

    var owlModifiers: UInt32 {
        UInt32(truncatingIfNeeded: modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue)
    }
}
