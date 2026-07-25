import CmuxAgentReplica

struct AgentTranscriptRowSelectionResolver {
    static func ask(rowID: String, rows: [AgentTranscriptRenderRow]) -> PendingAsk? {
        guard case .ask(let ask)? = content(rowID: rowID, rows: rows) else { return nil }
        return ask
    }

    static func activity(rowID: String, rows: [AgentTranscriptRenderRow]) -> TranscriptActivityDetails? {
        guard case .activity(let details)? = content(rowID: rowID, rows: rows) else { return nil }
        return details
    }

    static func failedTicket(rowID: String, rows: [AgentTranscriptRenderRow]) -> SendTicket? {
        guard case .pendingTicket(let ticket)? = content(rowID: rowID, rows: rows) else { return nil }
        return ticket
    }

    private static func content(
        rowID: String,
        rows: [AgentTranscriptRenderRow]
    ) -> AgentTranscriptRenderRow.Content? {
        rows.first { $0.id == rowID }?.content
    }
}
