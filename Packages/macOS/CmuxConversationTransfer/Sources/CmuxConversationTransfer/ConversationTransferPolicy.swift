/// Size and role policy applied when preparing a conversation handoff.
public struct ConversationTransferPolicy: Equatable, Sendable {
    /// Maximum number of Swift characters in the formatted handoff message.
    public let maximumCharacters: Int
    /// Maximum characters reserved for the conversation's opening user request.
    public let initialUserCharacterLimit: Int
    /// Whether system turns are eligible for transfer.
    public let includesSystemTurns: Bool
    /// Whether tool turns are eligible for transfer.
    public let includesToolTurns: Bool

    /// Creates a conversation transfer policy.
    /// - Parameters:
    ///   - maximumCharacters: Maximum formatted message size; values below 1,024 are raised to 1,024.
    ///   - initialUserCharacterLimit: Maximum characters reserved for the opening request.
    ///   - includesSystemTurns: Whether to transfer system and developer context.
    ///   - includesToolTurns: Whether to transfer tool calls and results.
    public init(
        maximumCharacters: Int = 24_000,
        initialUserCharacterLimit: Int = 4_000,
        includesSystemTurns: Bool = false,
        includesToolTurns: Bool = false
    ) {
        self.maximumCharacters = max(1_024, maximumCharacters)
        self.initialUserCharacterLimit = max(0, initialUserCharacterLimit)
        self.includesSystemTurns = includesSystemTurns
        self.includesToolTurns = includesToolTurns
    }

    /// Returns whether a turn role participates in the handoff.
    /// - Parameter role: The normalized role to evaluate.
    /// - Returns: `true` when turns with this role should be retained.
    public func includes(_ role: ConversationRole) -> Bool {
        switch role {
        case .user, .assistant:
            true
        case .system:
            includesSystemTurns
        case .tool:
            includesToolTurns
        case .event:
            false
        }
    }
}
