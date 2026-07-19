/// Acknowledges that the connection-wide interaction-mode stream is live.
struct BackendTerminalInteractionModeSubscriptionResponse: Decodable, Sendable {
    let status: String
}
