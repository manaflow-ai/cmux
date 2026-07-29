/// Converts normalized source turns into one compact target-harness prompt.
public struct ConversationTransferService: Sendable {
    private let compactor: any ConversationCompacting
    private let formatter: any ConversationFormatting
    private let policy: ConversationTransferPolicy

    /// Creates a transfer service from independently testable compaction and formatting policies.
    /// - Parameters:
    ///   - compactor: Strategy that selects turns within the message budget.
    ///   - formatter: Strategy that renders retained turns into one prompt.
    ///   - policy: Size and role policy applied to the conversation.
    public init(
        compactor: any ConversationCompacting = TailPreservingConversationCompactor(),
        formatter: any ConversationFormatting = RoleLabeledConversationFormatter(),
        policy: ConversationTransferPolicy = ConversationTransferPolicy()
    ) {
        self.compactor = compactor
        self.formatter = formatter
        self.policy = policy
    }

    /// Converts normalized turns into one compact handoff prompt.
    /// - Parameters:
    ///   - turns: Source turns in chronological order.
    ///   - sourceDisplayName: User-facing name of the source harness.
    /// - Returns: A sanitized message ready to seed the target harness.
    /// - Throws: ``ConversationTransferError/emptyConversation`` when no dialogue remains.
    public func message(
        for turns: [ConversationTurn],
        sourceDisplayName: String
    ) throws -> String {
        let formatter = self.formatter
        let compaction = compactor.compact(
            turns,
            policy: policy,
            formattedByteCount: { turn in
                formatter.formattedByteCount(of: turn)
            }
        )
        guard !compaction.turns.isEmpty else {
            throw ConversationTransferError.emptyConversation
        }
        return formatter.format(
            compaction,
            sourceDisplayName: sourceDisplayName,
            maximumBytes: policy.maximumBytes
        )
    }
}
