/// Client-side state for an acknowledged inline Feed mutation.
public enum MobileAgentFeedMutationState: Equatable, Sendable {
    case idle
    case sending
    case failed(message: String)
}
