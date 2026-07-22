/// Decides whether an action invocation should affect interactive command-palette ranking.
public enum CommandPaletteUsageRecordingPolicy {
    /// Returns `true` only when an interactive palette invocation was accepted.
    public static func shouldRecord(
        source: CmuxActionInvocationSource,
        result: CmuxActionExecutionResult
    ) -> Bool {
        guard source == .commandPalette else { return false }

        switch result {
        case .completed, .queued, .dispatched, .presented:
            return true
        case .requiresArguments, .invalidArguments, .invalidArgumentValues, .failed:
            return false
        }
    }
}
