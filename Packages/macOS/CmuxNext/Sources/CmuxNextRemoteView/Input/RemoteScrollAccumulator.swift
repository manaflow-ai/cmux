public import AppKit

/// Turns AppKit scroll deltas into `.scroll` events in hundredths, carrying
/// the sub-hundredth remainder so a slow trackpad gesture is not lost to
/// rounding. The wire has no phase field, so phases act here: a new gesture
/// (`began`, or the first momentum event) drops the previous remainder, and
/// momentum events are sent like the gesture (the host sees one smooth
/// stream; the viewer's momentum curve is kept).
public nonisolated struct RemoteScrollAccumulator: Sendable, Equatable {
    private var remainderX = 0.0
    private var remainderY = 0.0

    public init() {}

    /// One scroll event. `precise` deltas are points, else lines. Deltas
    /// follow AppKit's sign (positive = content moves down/right, the
    /// "natural" setting already applied by the system).
    public mutating func add(
        deltaX: Double, deltaY: Double, precise: Bool,
        phase: NSEvent.Phase, momentumPhase: NSEvent.Phase
    ) -> RemoteInputEvent? {
        if phase.contains(.began) || momentumPhase.contains(.began) || phase.contains(.mayBegin) {
            remainderX = 0
            remainderY = 0
        }
        let x = deltaX * 100 + remainderX
        let y = deltaY * 100 + remainderY
        let dx = x.rounded(.towardZero)
        let dy = y.rounded(.towardZero)
        remainderX = x - dx
        remainderY = y - dy
        if phase.contains(.ended) || phase.contains(.cancelled) || momentumPhase.contains(.ended) {
            remainderX = 0
            remainderY = 0
        }
        guard dx != 0 || dy != 0 else { return nil }
        return .scroll(dx: Self.clamp(dx), dy: Self.clamp(dy), precise: precise)
    }

    private static func clamp(_ value: Double) -> Int32 {
        Int32(max(Double(Int32.min), min(Double(Int32.max), value)))
    }
}
