import CmuxConversationTransfer
import Foundation

/// Converts supported source transcripts into one target-ready handoff prompt.
nonisolated struct AgentConversationExportService: Sendable {
    static let live = AgentConversationExportService()

    let readerRegistry: AgentConversationReaderRegistry
    let transferService: ConversationTransferService

    init(
        readerRegistry: AgentConversationReaderRegistry = .live,
        transferService: ConversationTransferService = ConversationTransferService()
    ) {
        self.readerRegistry = readerRegistry
        self.transferService = transferService
    }

    #if compiler(>=6.2)
    @concurrent
    #else
    @Sendable
    #endif
    func message(
        for snapshot: SessionRestorableAgentSnapshot,
        expectedTransferIdentity: AgentConversationTransferIdentity? = nil
    ) async throws -> String {
        let uncapturedSource = AgentConversationSource(snapshot: snapshot)
        let source = AgentConversationSource(
            snapshot: snapshot,
            expectedTransferIdentity: expectedTransferIdentity
                ?? uncapturedSource.transferIdentity
        )
        let turns = try await readerRegistry.read(source)
        do {
            return try transferService.message(
                for: turns.map(ConversationTurn.init),
                sourceDisplayName: snapshot.agentDisplayName
            )
        } catch ConversationTransferError.emptyConversation {
            throw AgentConversationExportError.emptyConversation
        }
    }
}

private extension ConversationTurn {
    init(_ turn: SessionTranscriptTurn) {
        self.init(id: turn.id, role: ConversationRole(turn.role), text: turn.text)
    }
}

private extension ConversationRole {
    init(_ role: SessionTranscriptRole) {
        switch role {
        case .user:
            self = .user
        case .assistant:
            self = .assistant
        case .system:
            self = .system
        case .tool:
            self = .tool
        case .event:
            self = .event
        }
    }
}
