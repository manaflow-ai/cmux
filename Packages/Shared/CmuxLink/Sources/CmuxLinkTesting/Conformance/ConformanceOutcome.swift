public enum ConformanceOutcome: Sendable, Hashable {
    case passed
    /// The harness cannot inject a fault the case needs.
    case skipped(String)
}
