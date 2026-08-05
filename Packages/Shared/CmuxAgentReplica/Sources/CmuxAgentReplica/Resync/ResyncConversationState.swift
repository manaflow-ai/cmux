import Foundation

/// Describes one open conversation for resync planning.
public struct ResyncConversationState: Codable, Hashable, Sendable {
    /// The open session identifier.
    public let sessionID: AgentSessionID
    /// The current journal identifier, if known.
    public let journalID: JournalID?
    /// Whether the conversation needs an explicit tail pull.
    ///
    /// The sync engine must pass `true` for every open conversation on transport-up,
    /// because disconnection alone never mutates the store or sets this flag.
    public let needsTailPull: Bool

    /// Creates an open-conversation planning value.
    /// - Parameters:
    ///   - sessionID: The open session identifier.
    ///   - journalID: The current journal identifier, if known.
    ///   - needsTailPull: Whether tail reconciliation is needed; pass `true` for
    ///     open conversations when transport reconnects.
    public init(sessionID: AgentSessionID, journalID: JournalID?, needsTailPull: Bool) {
        self.sessionID = sessionID
        self.journalID = journalID
        self.needsTailPull = needsTailPull
    }
}
