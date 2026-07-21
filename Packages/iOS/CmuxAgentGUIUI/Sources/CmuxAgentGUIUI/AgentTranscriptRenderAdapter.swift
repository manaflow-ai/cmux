#if os(iOS)
import CmuxAgentChat
import CmuxAgentGUIProjection
import CmuxAgentReplica
import Foundation

struct AgentTranscriptRenderRow: Identifiable, Equatable {
    let id: String
    let content: Content

    enum Content: Equatable {
        case message(ChatMessageRowSnapshot)
        case activity(TranscriptActivityDetails)
        case ask(PendingAsk)
        case metadata(String)
        case pendingTicket(SendTicket)
        case empty(TranscriptSyncPresentation)
    }
}

struct AgentTranscriptRenderAdapter {
    func rows(from projection: [TranscriptRow]) -> [AgentTranscriptRenderRow] {
        projection.compactMap(adapt)
    }

    private func adapt(_ row: TranscriptRow) -> AgentTranscriptRenderRow? {
        let content: AgentTranscriptRenderRow.Content
        switch row.rowKind {
        case .proseAgent(let text, let grouping):
            content = .message(message(row: row, role: .agent, text: text, grouping: grouping))
        case .proseUser(let text, _, let grouping):
            content = .message(message(row: row, role: .user, text: text, grouping: grouping))
        case .attachment(let attachment):
            content = .message(attachmentMessage(row: row, attachment: attachment))
        case .streaming(let textTail):
            content = .message(message(row: row, role: .agent, text: textTail, grouping: .single))
        case .pendingTicket(let ticket):
            content = .pendingTicket(ticket)
        case .pendingAsk(let ask):
            content = .ask(ask)
        case .activitySummary(let summary):
            guard let turnID = row.turnID else { return nil }
            content = .activity(TranscriptActivityDetails(turnID: turnID, summary: summary))
        case .activityItem(let item):
            guard let turnID = row.turnID else { return nil }
            content = .activity(TranscriptActivityDetails(
                turnID: turnID,
                summary: TranscriptActivitySummary(
                    editedFileCount: item.kind == .file ? 1 : 0,
                    readFileCount: 0,
                    searchedCode: false,
                    listedFiles: false,
                    commandCount: item.kind == .tool || item.kind == .command ? 1 : 0,
                    eventCount: 0,
                    items: [item]
                )
            ))
        case .genericActivity(let activity):
            content = .metadata([activity.kindLabel, activity.summary].joined(separator: ": "))
        case .status(let code, let detail):
            content = .metadata([AgentGUIL10n.statusCode(code), detail].compactMap(\.self).joined(separator: " · "))
        case .boundary:
            content = .metadata(AgentGUIL10n.string(
                "agent.transcript.boundary",
                defaultValue: "Earlier history is on your Mac"
            ))
        case .hole(let range):
            content = .metadata(AgentGUIL10n.hole(
                lowerBound: range.lowerBound.rawValue,
                upperBound: range.upperBound.rawValue
            ))
        case .unsupported(let rawKind, let summary):
            content = .metadata([rawKind, summary].joined(separator: ": "))
        case .dateHeader:
            return nil
        }
        return AgentTranscriptRenderRow(id: row.rowID.description, content: content)
    }

    private func message(
        row: TranscriptRow,
        role: ChatRole,
        text: String,
        grouping: TranscriptProseGrouping
    ) -> ChatMessageRowSnapshot {
        let timestamp: Date
        if let milliseconds = row.sourceEntry?.timestampMilliseconds {
            timestamp = Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
        } else {
            timestamp = Date(timeIntervalSince1970: TimeInterval(row.displayTick ?? 0) / 1_000)
        }
        let message = ChatMessage(
            id: row.rowID.description,
            seq: row.sourceEntry?.seq.rawValue ?? row.displayTick ?? 0,
            role: role,
            timestamp: timestamp,
            kind: .prose(ChatProse(text: text))
        )
        return ChatMessageRowSnapshot(
            message: message,
            groupPosition: groupPosition(grouping),
            showsTimestamp: row.sourceEntry?.timestampMilliseconds != nil
                && (grouping == .single || grouping == .last)
        )
    }

    private func groupPosition(_ grouping: TranscriptProseGrouping) -> ChatGroupPosition {
        switch grouping {
        case .single: .solo
        case .first: .first
        case .middle: .middle
        case .last: .last
        }
    }

    private func attachmentMessage(
        row: TranscriptRow,
        attachment: AttachmentPayload
    ) -> ChatMessageRowSnapshot {
        let isImage = attachment.mimeType?.hasPrefix("image/") == true
            || attachment.kind.lowercased().contains("image")
        let message = ChatMessage(
            id: row.rowID.description,
            seq: row.sourceEntry?.seq.rawValue ?? row.displayTick ?? 0,
            role: .user,
            timestamp: row.sourceEntry?.timestampMilliseconds.map {
                Date(timeIntervalSince1970: Double($0) / 1_000)
            } ?? Date(timeIntervalSince1970: 0),
            kind: .attachment(ChatAttachment(
                media: isImage ? .image : .file,
                displayName: attachment.displayName ?? attachment.summary,
                hostPath: attachment.hostPath
            ))
        )
        return ChatMessageRowSnapshot(
            message: message,
            groupPosition: .solo,
            showsTimestamp: row.sourceEntry?.timestampMilliseconds != nil
        )
    }
}
#endif
