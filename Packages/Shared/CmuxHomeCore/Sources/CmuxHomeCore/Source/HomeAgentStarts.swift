import Foundation

/// The Chief's agents that have a session now, and when each session began: what ``HomeSource/agentStarts()``
/// yields.
///
/// An agent queued behind the Chief's cap starts with no word in the chat, so ``peers`` is how Home learns it
/// started; ``startedAt`` is how long it has really worked, since an agent that waited in the queue or took a
/// while to spawn starts later than the Chief's message to it (its agent pill counts from here).
///
/// ```swift
/// HomeAgentStarts(peers: ["a1017"], startedAt: ["a1017": sessionCreated])
/// ```
public struct HomeAgentStarts: Hashable, Sendable {
    /// The agent ids (`a<n>`) that have a session.
    public var peers: Set<String>
    /// When each agent's newest session began, by agent id; an agent whose session start is not known is left out.
    public var startedAt: [String: Date]

    /// Makes the set.
    ///
    /// - Parameters:
    ///   - peers: The agent ids (`a<n>`) that have a session.
    ///   - startedAt: When each agent's newest session began; empty (the default) when the owner cannot say.
    public init(peers: Set<String> = [], startedAt: [String: Date] = [:]) {
        self.peers = peers
        self.startedAt = startedAt
    }
}
