/// Timing bounds for coalesced terminal-state evaluation.
public struct AgentTerminalDetectionConfiguration: Sendable, Equatable {
    /// Intended quiet period after the newest output invalidation.
    public let quietWindow: Duration
    /// Maximum time a sustained burst may defer evaluation.
    public let maximumLatency: Duration

    /// Creates bounded scheduler timing.
    public init(quietWindow: Duration = .milliseconds(90), maximumLatency: Duration = .milliseconds(350)) {
        self.quietWindow = quietWindow
        self.maximumLatency = maximumLatency
    }
}
