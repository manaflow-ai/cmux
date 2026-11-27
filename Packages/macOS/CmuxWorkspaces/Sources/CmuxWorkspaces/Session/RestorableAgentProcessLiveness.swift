/// Process evidence used to decide whether a restorable agent should resume automatically.
public enum RestorableAgentProcessLiveness: Equatable, Hashable, Sendable {
    /// A matching agent process was observed.
    case running
    /// The recorded agent process generation was confirmed to have exited.
    case exited
    /// Available evidence cannot determine whether the recorded agent is running.
    case unknown

    /// Revalidates cached running state against current process-generation evidence.
    ///
    /// Non-running states are already authoritative. A cached running state remains
    /// running only when at least one recorded generation still matches; otherwise an
    /// uncertain observation produces ``unknown`` and definitive mismatches produce ``exited``.
    ///
    /// - Parameter processMatches: Current evidence for every recorded process generation.
    /// - Returns: The liveness classification after revalidation.
    public func revalidated<ProcessMatches: Sequence>(
        against processMatches: ProcessMatches
    ) -> Self where ProcessMatches.Element == RestorableAgentProcessMatch {
        guard self == .running else { return self }

        var foundRecordedProcess = false
        var foundUnknownProcess = false
        for processMatch in processMatches {
            foundRecordedProcess = true
            switch processMatch {
            case .matches:
                return .running
            case .mismatches:
                continue
            case .unknown:
                foundUnknownProcess = true
            }
        }
        guard foundRecordedProcess else { return .unknown }
        return foundUnknownProcess ? .unknown : .exited
    }

    /// Resolves the saved running flag after process revalidation.
    ///
    /// Confirmed current runtime evidence supersedes cached and shell state.
    /// Shell activity is used only when process evidence remains unknown.
    ///
    /// - Parameters:
    ///   - shellActivityState: The latest shell-integration state for the panel.
    ///   - hasConfirmedRuntimeProcess: Whether the panel owns a matching live agent process generation.
    /// - Returns: Whether the agent was running, or `nil` when available evidence is inconclusive.
    public func resolvedWasRunning(
        fallingBackTo shellActivityState: PanelShellActivityState?,
        hasConfirmedRuntimeProcess: Bool
    ) -> Bool? {
        if hasConfirmedRuntimeProcess {
            return true
        }
        switch self {
        case .running:
            return true
        case .exited:
            return false
        case .unknown:
            switch shellActivityState {
            case .some(.commandRunning):
                return true
            case .some(.promptIdle):
                return false
            case .some(.unknown), .none:
                return nil
            }
        }
    }
}
