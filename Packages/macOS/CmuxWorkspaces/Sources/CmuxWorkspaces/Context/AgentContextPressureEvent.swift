/// One newly observed context-pressure signal.
public struct AgentContextPressureEvent: Codable, Equatable, Sendable {
    /// The provider that emitted the signal.
    public let provider: AgentContextProvider
    /// The normalized signal classification.
    public let signal: AgentContextPressureSignal
    /// Number of matching occurrences observed for this signal.
    public let occurrence: Int

    /// Creates a pressure event.
    ///
    /// - Parameters:
    ///   - provider: The provider that emitted the evidence.
    ///   - signal: The normalized pressure classification.
    ///   - occurrence: The cumulative match count for the signal.
    public init(
        provider: AgentContextProvider,
        signal: AgentContextPressureSignal,
        occurrence: Int
    ) {
        self.provider = provider
        self.signal = signal
        self.occurrence = occurrence
    }
}
