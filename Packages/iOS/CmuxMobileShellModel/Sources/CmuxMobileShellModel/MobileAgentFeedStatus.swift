/// Loading and capability state for the cross-Mac coding-agent Feed.
public enum MobileAgentFeedStatus: Equatable, Sendable {
    case idle
    case loading
    case ready
    case offlineCached
    case partial
    case reconnecting
    case unavailable
    case requiresMacUpdate
    case failed
}
