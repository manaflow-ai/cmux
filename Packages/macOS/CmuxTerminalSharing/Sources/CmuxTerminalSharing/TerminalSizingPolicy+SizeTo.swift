import CmuxTerminalSizing

extension TerminalSizingPolicy {
    /// The policy that makes `participant` set the grid ("Size to My Window").
    ///
    /// - `priority`: moves the participant's priority key to the top.
    /// - `fixed`: fixes the grid at the participant's viewport.
    /// - `smallest`, `largest`: switches to `latest`, where the caller's
    ///   activity then makes the participant the owner.
    /// - `latest`: unchanged; activity alone decides.
    ///
    /// - Parameter participant: the participant that should own the grid.
    /// - Returns: the adjusted policy.
    public func sizedTo(_ participant: TerminalSizingParticipant) -> TerminalSizingPolicy {
        switch mode {
        case .latest:
            return self
        case .smallest, .largest:
            return TerminalSizingPolicy(mode: .latest, priority: priority, fixed: fixed)
        case .priority:
            let key = participant.priorityKey
            return TerminalSizingPolicy(mode: .priority, priority: [key] + priority.filter { $0 != key }, fixed: fixed)
        case .fixed:
            guard let viewport = participant.viewport else { return self }
            return TerminalSizingPolicy(mode: .fixed, priority: priority, fixed: viewport)
        }
    }

    /// The same policy in another mode, keeping the priority list and fixed grid.
    ///
    /// - Parameters:
    ///   - mode: the new mode.
    ///   - fallbackFixed: the grid `fixed` uses when no fixed grid is set yet.
    /// - Returns: the adjusted policy.
    public func withMode(_ mode: TerminalSizingMode, fallbackFixed: TerminalGridSize) -> TerminalSizingPolicy {
        TerminalSizingPolicy(
            mode: mode,
            priority: priority,
            fixed: mode == .fixed ? (fixed ?? fallbackFixed) : fixed
        )
    }
}
