public import Foundation

/// Where the user's Chief runs and how it is doing (brains/DESIGN-cmux-lawrence.md):
/// the paired server its brain is placed on, and a state read from its main
/// conversation. The cloud has no presence for a brain, so the state says
/// what the conversation shows: the Chief answered the last message
/// (`ready`), a message waits a short while (`thinking`), or a message has
/// waited long enough that the brain is likely down (`notAnswering`).
public nonisolated struct ChiefPlacementStatus: Sendable, Equatable {
    public nonisolated enum State: Sendable, Equatable {
        case ready
        case thinking
        case notAnswering
    }

    public var serverName: String
    public var chiefName: String
    public var state: State
    /// The Chief's newest message, or nil before its first reply.
    public var lastReply: Date?

    public init(serverName: String, chiefName: String, state: State, lastReply: Date?) {
        self.serverName = serverName
        self.chiefName = chiefName
        self.state = state
        self.lastReply = lastReply
    }
}
