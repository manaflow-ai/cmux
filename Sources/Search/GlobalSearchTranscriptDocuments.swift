import CmuxAgentChat
import Foundation

struct GlobalSearchTranscriptDocuments {
    static func transcriptDocumentID(sessionID: String, ordinal: Int) -> String {
        "session:\(sessionID):transcript:\(ordinal)"
    }

    static func commandDocumentID(sessionID: String, ordinal: Int) -> String {
        "session:\(sessionID):command:\(ordinal)"
    }

    static func sessionDocumentPrefix(sessionID: String) -> String {
        "session:\(sessionID):"
    }

    static func transcriptDocument(
        sessionID: String,
        ordinal: Int,
        routing: GlobalSearchTranscriptRouting,
        title: String,
        anchorSeq: Int,
        text: String
    ) -> SearchIndexDocument {
        SearchIndexDocument(
            id: transcriptDocumentID(sessionID: sessionID, ordinal: ordinal),
            windowID: routing.windowID,
            workspaceID: routing.workspaceID,
            panelID: routing.panelID,
            kind: .transcript,
            title: title,
            location: routing.location,
            anchor: "\(anchorSeq)",
            text: GlobalSearchDocuments.cappedText(text, limit: GlobalSearchIndexingLimits.maxTranscriptChunkCharacters)
        )
    }

    static func commandDocument(
        sessionID: String,
        ordinal: Int,
        routing: GlobalSearchTranscriptRouting,
        title: String,
        anchorSeq: Int,
        text: String
    ) -> SearchIndexDocument {
        SearchIndexDocument(
            id: commandDocumentID(sessionID: sessionID, ordinal: ordinal),
            windowID: routing.windowID,
            workspaceID: routing.workspaceID,
            panelID: routing.panelID,
            kind: .command,
            title: title,
            location: routing.location,
            anchor: "\(anchorSeq)",
            text: GlobalSearchDocuments.cappedText(text, limit: GlobalSearchIndexingLimits.maxCommandChunkCharacters)
        )
    }

    static func transcriptText(for message: ChatMessage) -> String? {
        switch message.kind {
        case .prose(let prose):
            return nonEmpty(prose.text)
        case .thought(let thought):
            return nonEmpty(thought.text)
        case .toolUse(let toolUse):
            return joined([
                toolUse.toolName,
                toolUse.summary,
                toolUse.inputDetail,
                toolUse.output
            ])
        case .question(let question):
            return joined([
                question.prompt,
                question.options.map { joined([$0.label, $0.detail]) }.joined(separator: "\n"),
                question.selectedOptionLabel
            ])
        case .status(let status):
            return joined([status.event.rawValue, status.detail])
        case .terminal, .fileEdit, .permissionRequest, .attachment, .unsupported:
            return nil
        }
    }

    static func commandText(for message: ChatMessage) -> String? {
        guard case .terminal(let capture) = message.kind else { return nil }
        return joined([
            capture.command,
            capture.output.map {
                GlobalSearchDocuments.cappedText($0, limit: GlobalSearchIndexingLimits.maxCommandOutputCharacters)
            }
        ])
    }

    private static func joined(_ values: [String?]) -> String? {
        let text = values
            .compactMap { nonEmpty($0) }
            .joined(separator: "\n")
        return nonEmpty(text)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
