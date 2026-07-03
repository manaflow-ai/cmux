import CmuxFoundation
import Foundation
import SwiftUI

struct SessionTranscriptTurn: Identifiable, Equatable, Sendable {
    let id: Int
    let role: SessionTranscriptRole
    let text: String
}

enum SessionTranscriptRole: Equatable, Sendable {
    case user
    case assistant
    case system
    case tool
    case event

    var label: String {
        switch self {
        case .user:
            return String(localized: "sessionIndex.preview.role.user", defaultValue: "You")
        case .assistant:
            return String(localized: "sessionIndex.preview.role.assistant", defaultValue: "Agent")
        case .system:
            return String(localized: "sessionIndex.preview.role.system", defaultValue: "System")
        case .tool:
            return String(localized: "sessionIndex.preview.role.tool", defaultValue: "Tool")
        case .event:
            return String(localized: "sessionIndex.preview.role.event", defaultValue: "Event")
        }
    }

    // Per-role transcript body font (restored during the main merge, which added
    // bodyFontSize/bodyFontDesign but the consumer, SessionIndexView, reads a
    // combined `bodyFont`).
    var bodyFontSize: CGFloat {
        switch self {
        case .tool, .system:
            return 11
        case .user, .assistant, .event:
            return 12
        }
    }

    var bodyFontDesign: Font.Design {
        switch self {
        case .tool, .system:
            return .monospaced
        case .user, .assistant, .event:
            return .default
        }
    }

    var bodyFont: Font {
        .system(size: bodyFontSize, design: bodyFontDesign)
    }

    var foregroundColor: Color {
        switch self {
        case .user: return .accentColor
        case .assistant: return .green
        case .system: return .secondary
        case .tool: return .orange
        case .event: return .secondary
        }
    }

    var backgroundColor: Color {
        switch self {
        case .user: return Color.accentColor.opacity(0.035)
        case .assistant: return Color.green.opacity(0.035)
        case .system: return Color.primary.opacity(0.025)
        case .tool: return Color.orange.opacity(0.035)
        case .event: return Color.primary.opacity(0.02)
        }
    }

    var bodyFontSize: CGFloat {
        switch self {
        case .tool, .system:
            return 11
        case .user, .assistant, .event:
            return 12
        }
    }

    var bodyFontDesign: Font.Design {
        switch self {
        case .tool, .system:
            return .monospaced
        case .user, .assistant, .event:
            return .default
        }
    }
}

extension SessionTranscriptRole {
    /// Classifies a transcript record's raw role string onto a
    /// `SessionTranscriptRole`. Returns nil only when `raw` is nil; any
    /// unrecognized non-nil role collapses to `.event`, matching the legacy
    /// transcript classifier exactly.
    init?(transcriptRaw raw: String?) {
        guard let raw else { return nil }
        switch raw.lowercased() {
        case "user":
            self = .user
        case "assistant":
            self = .assistant
        case "system", "developer":
            self = .system
        case "tool", "tool_use", "tool_result", "function_call", "function_call_output":
            self = .tool
        default:
            self = .event
        }
    }
}

extension SessionTranscriptTurn {
    private static let maxTurnTextCharacters = 40_000

    /// Extracts and normalizes the display text for a turn from a decoded
    /// transcript content value, joining non-empty fragments and applying the
    /// Claude user-prompt title heuristic. Returns nil when there is no text.
    static func normalizedText(
        from value: Any?,
        role: SessionTranscriptRole,
        agent: SessionAgent
    ) -> String? {
        let text = TranscriptContentFragments(value).fragments
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        guard !text.isEmpty else { return nil }
        if agent == .claude, role == .user {
            return SessionEntry.claudeDisplayTitle(from: text)
                .map { truncatedText($0, role: role) }
        }
        return truncatedText(text, role: role)
    }

    /// Merges consecutive turns that share a role into a single turn, then
    /// renumbers ids so the rendered list stays contiguous.
    static func coalesce(_ turns: [SessionTranscriptTurn]) -> [SessionTranscriptTurn] {
        var output: [SessionTranscriptTurn] = []
        for turn in turns {
            if let last = output.last, last.role == turn.role {
                output[output.count - 1] = SessionTranscriptTurn(
                    id: last.id,
                    role: last.role,
                    text: last.text + "\n\n" + turn.text
                )
            } else {
                output.append(turn)
            }
        }
        return output.enumerated().map { offset, turn in
            SessionTranscriptTurn(id: offset, role: turn.role, text: turn.text)
        }
    }

    /// Truncates a turn's text to the per-role preview character budget, adding
    /// the localized truncation marker when the limit is exceeded.
    static func truncatedText(_ text: String, role: SessionTranscriptRole) -> String {
        let limit = role == .tool ? 12_000 : maxTurnTextCharacters
        guard text.count > limit else { return text }
        let index = text.index(text.startIndex, offsetBy: limit)
        let marker = String(localized: "sessionIndex.preview.truncated", defaultValue: "Preview truncated")
        return String(text[..<index]) + "\n\n" + marker
    }

    /// A placeholder turn standing in for a single transcript record too large
    /// to include in the preview.
    static func largeRecordTurn(id: Int, role: SessionTranscriptRole) -> SessionTranscriptTurn {
        SessionTranscriptTurn(
            id: id,
            role: role,
            text: String(
                localized: "sessionIndex.preview.largeRecord",
                defaultValue: "Large transcript record omitted"
            )
        )
    }

    /// Appends the localized "preview truncated" marker turn when the preview
    /// hit its turn-count cap.
    static func appendTurnLimitMarker(to turns: inout [SessionTranscriptTurn], id: Int) {
        turns.append(
            SessionTranscriptTurn(
                id: id,
                role: .event,
                text: String(localized: "sessionIndex.preview.truncated", defaultValue: "Preview truncated")
            )
        )
    }
}

/// A single rendered line in the transcript preview. `rows(from:)` chunks each
/// turn's text into wrappable segments, marking every segment after the first as
/// a continuation so the role label is only drawn once per turn.
struct SessionTranscriptDisplayRow: Identifiable, Equatable {
    let id: String
    let role: SessionTranscriptRole
    let text: String
    let isContinuation: Bool

    static func rows(from turns: [SessionTranscriptTurn]) -> [SessionTranscriptDisplayRow] {
        turns.flatMap { turn in
            turn.text.transcriptChunks().enumerated().map { offset, chunk in
                SessionTranscriptDisplayRow(
                    id: "\(turn.id)-\(offset)",
                    role: turn.role,
                    text: chunk,
                    isContinuation: offset > 0
                )
            }
        }
    }
}
