import AppKit

extension GhosttyNSView {
    /// Whether a scroll event should receive the historical 2x delta boost.
    ///
    /// Convenience over ``shouldDoublePreciseScrollDelta(hasPreciseScrollingDeltas:phase:momentumPhase:)``
    /// so the `scrollWheel` call site stays a single readable line. The
    /// decomposed overload exists separately because unit tests cannot
    /// synthesize a real `NSEvent`.
    static func shouldDoublePreciseScrollDelta(for event: NSEvent) -> Bool {
        shouldDoublePreciseScrollDelta(
            hasPreciseScrollingDeltas: event.hasPreciseScrollingDeltas,
            phase: event.phase,
            momentumPhase: event.momentumPhase
        )
    }

    /// Whether a precise-delta scroll event should receive the historical 2x
    /// delta boost.
    ///
    /// macOS reports `hasPreciseScrollingDeltas == true` for both trackpads /
    /// Magic Mouse and high-resolution mice (for example Logitech free-spin
    /// wheels). cmux has always doubled every precise delta, which stacked a 2x
    /// boost on top of the acceleration macOS already applies. On a high-res
    /// mouse that made scrolling feel runaway.
    ///
    /// Only gesture-driven devices drive a continuous `phase` / `momentumPhase`;
    /// plain wheels (notched or high-res) leave both empty. Gating the boost on
    /// that signal keeps the familiar faster feel for trackpads while letting
    /// mice scroll at the OS-accelerated rate.
    static func shouldDoublePreciseScrollDelta(
        hasPreciseScrollingDeltas: Bool,
        phase: NSEvent.Phase,
        momentumPhase: NSEvent.Phase
    ) -> Bool {
        guard hasPreciseScrollingDeltas else { return false }
        return !phase.isEmpty || !momentumPhase.isEmpty
    }
}
