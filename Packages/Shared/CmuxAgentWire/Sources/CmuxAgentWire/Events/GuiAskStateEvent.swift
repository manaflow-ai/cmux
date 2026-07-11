public import CmuxAgentReplica

/// Event payload carrying the whole current pending-ask value.
public struct GuiAskStateEvent: Codable, Hashable, Sendable {
    /// The whole current pending-ask value.
    public let ask: PendingAsk

    /// Creates an ask-state payload.
    /// - Parameter ask: The whole current pending-ask value.
    public init(ask: PendingAsk) {
        self.ask = ask
    }
}
