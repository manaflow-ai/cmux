extension CmuxActionExecutionResult {
    /// Returns whether this result should affect interactive command-palette ranking.
    ///
    /// - Parameter source: The adapter that invoked the action.
    /// - Returns: `true` only for accepted interactive command-palette invocations.
    public func shouldRecordCommandPaletteUsage(for source: CmuxActionInvocationSource) -> Bool {
        switch source {
        case .commandPalette:
            switch self {
            case .completed, .queued, .dispatched, .presented:
                true
            case .requiresArguments, .invalidArguments, .invalidArgumentValues, .failed:
                false
            }
        case .automation:
            false
        }
    }
}
