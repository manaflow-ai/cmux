/// One provider-specific textual pressure pattern and its event threshold.
struct AgentContextPressurePattern: Sendable {
    let signal: AgentContextPressureSignal
    let markers: [String]
    let eventThreshold: Int
    /// Optional provider footer phrases preceded or followed by a remaining percentage.
    let lowContextPercentageThreshold: Int?
    let lowContextPercentagePhrases: [String]

    init(
        signal: AgentContextPressureSignal,
        markers: [String],
        eventThreshold: Int,
        lowContextPercentageThreshold: Int? = nil,
        lowContextPercentagePhrases: [String] = []
    ) {
        self.signal = signal
        self.markers = markers
        self.eventThreshold = eventThreshold
        self.lowContextPercentageThreshold = lowContextPercentageThreshold
        self.lowContextPercentagePhrases = lowContextPercentagePhrases
    }
}
