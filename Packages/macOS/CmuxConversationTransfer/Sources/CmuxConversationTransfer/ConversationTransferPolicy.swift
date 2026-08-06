/// Size and role policy applied when preparing a conversation handoff.
public struct ConversationTransferPolicy: Equatable, Sendable {
    /// Maximum number of UTF-8 bytes in the formatted handoff message.
    public let maximumBytes: Int
    /// Maximum UTF-8 bytes reserved for the conversation's opening user request.
    public let initialUserByteLimit: Int
    /// Whether system turns are eligible for transfer.
    public let includesSystemTurns: Bool
    /// Whether tool turns are eligible for transfer.
    public let includesToolTurns: Bool

    /// Creates a conversation transfer policy.
    /// - Parameters:
    ///   - maximumBytes: Maximum formatted UTF-8 size; values below 1,024 are raised to 1,024.
    ///   - initialUserByteLimit: Maximum UTF-8 bytes reserved for the opening request.
    ///   - includesSystemTurns: Whether to transfer system and developer context.
    ///   - includesToolTurns: Whether to transfer tool calls and results.
    public init(
        maximumBytes: Int = 24_000,
        initialUserByteLimit: Int = 4_000,
        includesSystemTurns: Bool = false,
        includesToolTurns: Bool = false
    ) {
        self.maximumBytes = max(1_024, maximumBytes)
        self.initialUserByteLimit = max(0, initialUserByteLimit)
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
