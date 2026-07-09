import CMUXAgentLaunch
import Foundation

/// Reads a Hermes agent session's SQLite-backed transcript into the
/// `[SessionTranscriptTurn]` preview model the popover renders. A value type
/// carrying the preview turn cap so the limit is explicit and substitutable;
/// `load(sessionId:)` does the synchronous query work and is meant to be
/// called from a detached background task so presenting the popover only flips
/// UI state.
struct HermesTranscriptReader: Sendable {
    /// Maximum number of turns kept in the preview before a truncation marker
    /// is appended.
    private let maxPreviewTurns: Int

    init(maxPreviewTurns: Int) {
        self.maxPreviewTurns = maxPreviewTurns
    }

    func load(sessionId: String) throws -> [SessionTranscriptTurn] {
        do {
            let turns = try HermesAgentIndex.loadTranscript(sessionId: sessionId, limit: maxPreviewTurns + 1)
            let didHitTurnLimit = turns.count > maxPreviewTurns
            var previewTurns: [SessionTranscriptTurn] = turns.prefix(maxPreviewTurns).enumerated().compactMap { index, turn -> SessionTranscriptTurn? in
                let role: SessionTranscriptRole = (turn.toolName?.isEmpty == false) ? .tool : (SessionTranscriptRole(transcriptRaw: turn.role) ?? .event)
                let text: String
                if role == .tool, let toolName = turn.toolName, !toolName.isEmpty {
                    text = [toolName, turn.content].joined(separator: "\n\n")
                } else {
                    text = turn.content
                }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                return SessionTranscriptTurn(id: index, role: role, text: SessionTranscriptTurn.truncatedText(trimmed, role: role))
            }
            if didHitTurnLimit {
                SessionTranscriptTurn.appendTurnLimitMarker(to: &previewTurns, id: previewTurns.count)
            }
            return SessionTranscriptTurn.coalesce(previewTurns)
        } catch HermesAgentIndexError.missingDatabase {
            throw SessionTranscriptLoadError.missingFile
        } catch let HermesAgentIndexError.sqlite(message) {
            throw SessionTranscriptLoadError.databaseError(message)
        }
    }
}
