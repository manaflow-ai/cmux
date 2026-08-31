/// The pure state machine behind the collapsed sidebar's hover-reveal.
///
/// Holds no timers, no views, and no clock: it maps `(state, event)` to a new
/// state plus the timers its owner should start or cancel. Every timing and
/// dismissal rule that makes a hover panel bearable lives here and is unit
/// tested without a run loop.
///
/// ```swift
/// var state = SidebarPeekState.idle
/// let machine = SidebarPeekMachine(policy: .default)
/// let effects = machine.apply(.pointerEnteredEdge, to: &state)
/// // effects == [.startDwellTimer]
/// ```
public struct SidebarPeekMachine: Sendable {
    /// The timing and behaviour policy this machine enforces.
    public let policy: SidebarPeekPolicy

    /// Creates a machine bound to `policy`.
    ///
    /// - Parameter policy: Timings and behaviour flags to enforce.
    public init(policy: SidebarPeekPolicy = .default) {
        self.policy = policy
    }

    /// Applies `event` to `state`, returning the timers to start or cancel.
    ///
    /// - Parameters:
    ///   - event: The interaction that occurred.
    ///   - state: The state to advance, mutated in place.
    /// - Returns: Timer effects for the caller to perform, in order.
    @discardableResult
    public func apply(
        _ event: SidebarPeekEvent,
        to state: inout SidebarPeekState
    ) -> [SidebarPeekEffect] {
        switch event {
        case .sidebarDocked:
            // A docked sidebar makes peek meaningless. Drop every hold too, so
            // a menu that was open over the panel cannot strand the machine in
            // a held state after the panel is gone.
            state.setPhase(.idle)
            state.clearHolds()
            return [.cancelDwellTimer, .cancelGraceTimer]

        case .sidebarCollapsed:
            state.setPhase(.idle)
            state.clearHolds()
            return [.cancelDwellTimer, .cancelGraceTimer]

        case .pointerEnteredEdge:
            guard policy.isEnabled else { return [] }
            switch state.phase {
            case .idle:
                state.setPhase(.arming)
                return [.startDwellTimer]
            case .dismissing:
                // Back at the edge before grace ran out: keep the panel and
                // stop the countdown rather than dismissing and re-revealing.
                state.setPhase(.peeking)
                return [.cancelGraceTimer]
            case .arming, .peeking:
                return []
            }

        case .dragEnteredEdge:
            guard policy.isEnabled else { return [] }
            // A drag has already declared intent, so it skips dwell entirely.
            state.setPhase(.peeking)
            state.insert(.dragInFlight)
            return [.cancelDwellTimer, .cancelGraceTimer]

        case .pointerExitedEdge:
            switch state.phase {
            case .arming:
                // Left before dwell finished: this was a pass-through, not a
                // request. Nothing was shown, so nothing needs dismissing.
                state.setPhase(.idle)
                return [.cancelDwellTimer]
            case .peeking:
                return beginDismissalIfUnheld(&state)
            case .idle, .dismissing:
                return []
            }

        case .dwellElapsed:
            guard state.phase == .arming else { return [] }
            state.setPhase(.peeking)
            return []

        case .graceElapsed:
            guard state.phase == .dismissing else { return [] }
            // A hold acquired after the timer started but before it fired must
            // still win; the phase check alone would not catch that.
            guard !state.holds.isHolding else {
                state.setPhase(.peeking)
                return [.cancelGraceTimer]
            }
            state.setPhase(.idle)
            return []

        case .holdAcquired(let hold):
            state.insert(hold)
            guard state.phase != .idle else { return [] }
            state.setPhase(.peeking)
            return [.cancelDwellTimer, .cancelGraceTimer]

        case .holdReleased(let hold):
            state.remove(hold)
            guard state.phase == .peeking else { return [] }
            return beginDismissalIfUnheld(&state)

        case .workspaceActivated:
            guard policy.dismissesOnWorkspaceActivation else { return [] }
            guard state.phase.presentsPanel else { return [] }
            // Deliberate: no grace period. The user said where they were going,
            // so the panel gets out of the way immediately instead of hovering
            // over the content they just asked for.
            state.setPhase(.idle)
            state.clearHolds()
            return [.cancelDwellTimer, .cancelGraceTimer]

        case .escapePressed:
            guard state.phase != .idle else { return [] }
            state.setPhase(.idle)
            state.clearHolds()
            return [.cancelDwellTimer, .cancelGraceTimer]
        }
    }

    /// Starts dismissal, unless something is still holding the panel open.
    private func beginDismissalIfUnheld(
        _ state: inout SidebarPeekState
    ) -> [SidebarPeekEffect] {
        guard !state.holds.isHolding else { return [] }
        state.setPhase(.dismissing)
        return [.startGraceTimer]
    }
}
