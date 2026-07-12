import CmuxAgentSync

struct FixedAgentSyncJitter: AgentSyncJitter {
    let fraction: Double

    func retryJitterFraction() -> Double {
        fraction
    }
}
