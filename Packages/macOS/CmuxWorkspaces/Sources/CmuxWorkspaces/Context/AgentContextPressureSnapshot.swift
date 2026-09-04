/// A value snapshot of the pressure state for one managed agent pane.
public struct AgentContextPressureSnapshot: Codable, Equatable, Sendable {
    /// Whether at least one pressure signal has been observed since the last reset.
    public let isUnderPressure: Bool
    /// Signals observed so far, in first-observation order.
    public let detectedSignals: [AgentContextPressureSignal]
    /// Total matches by signal.
    public let occurrences: [AgentContextPressureSignal: Int]

    /// Creates a pressure snapshot.
    ///
    /// - Parameters:
    ///   - isUnderPressure: Whether at least one signal crossed its threshold.
    ///   - detectedSignals: Signals in first-observation order.
    ///   - occurrences: Cumulative marker matches grouped by signal.
    public init(
        isUnderPressure: Bool = false,
        detectedSignals: [AgentContextPressureSignal] = [],
        occurrences: [AgentContextPressureSignal: Int] = [:]
    ) {
        self.isUnderPressure = isUnderPressure
        self.detectedSignals = detectedSignals
        self.occurrences = occurrences
    }
}
