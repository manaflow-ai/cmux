/// When each machine's last typing-prewarm resume failed, for `cloud_handler_prewarm`'s `sinceFailureMs`.
@MainActor
public final class AgentPaneCloudPrewarmFailures {
    private var at: [String: ContinuousClock.Instant] = [:]
    public init() {}
    public func failed(_ id: String) { at[id] = .now }
    public func clear(_ id: String) { at[id] = nil }
    public func sinceFailureMs(_ id: String) -> Int? {
        guard let start = at[id] else { return nil }
        let d = start.duration(to: .now)
        return Int(d.components.seconds * 1000 + d.components.attoseconds / 1_000_000_000_000_000)
    }
}
