import AppKit

/// Classifies a terminal scroll event for cmux's historical precise-delta boost.
struct GhosttyTerminalScrollBoost {
    /// Whether AppKit marked the scroll event as carrying precise deltas.
    let hasPreciseScrollingDeltas: Bool
    /// The gesture phase reported by AppKit for active scroll gestures.
    let phase: NSEvent.Phase
    /// The momentum phase reported by AppKit after a gesture ends.
    let momentumPhase: NSEvent.Phase

    /// Creates a boost classifier from the AppKit scroll attributes cmux uses.
    init(
        hasPreciseScrollingDeltas: Bool,
        phase: NSEvent.Phase,
        momentumPhase: NSEvent.Phase
    ) {
        self.hasPreciseScrollingDeltas = hasPreciseScrollingDeltas
        self.phase = phase
        self.momentumPhase = momentumPhase
    }

    /// Creates a boost classifier from a concrete AppKit scroll event.
    init(event: NSEvent) {
        self.init(
            hasPreciseScrollingDeltas: event.hasPreciseScrollingDeltas,
            phase: event.phase,
            momentumPhase: event.momentumPhase
        )
    }

    /// Whether the event should receive cmux's historical 2x precise-delta boost.
    var shouldDoublePreciseScrollDelta: Bool {
        guard hasPreciseScrollingDeltas else { return false }
        return !phase.isEmpty || !momentumPhase.isEmpty
    }
}

extension GhosttyNSView {
    /// Whether a scroll event should receive the historical 2x delta boost.
    static func shouldDoublePreciseScrollDelta(for event: NSEvent) -> Bool {
        GhosttyTerminalScrollBoost(event: event).shouldDoublePreciseScrollDelta
    }
}
