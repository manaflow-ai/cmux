import CmuxAgentChat
import Foundation

extension AgentChatTranscriptService {
    /// Whether a batch carries committed agent prose that settles live preview.
    static func batchContainsAgentProse(_ messages: [ChatMessage]) -> Bool {
        messages.contains { message in
            guard message.role == .agent else { return false }
            if case .prose = message.kind { return true }
            return false
        }
    }

    /// Completion timestamp for a batch that contains no unfinished agent work.
    static func completedAssistantTurnTimestamp(in messages: [ChatMessage]) -> Date? {
        guard !messages.isEmpty else { return nil }
        var completedAt: Date?
        for message in messages where message.role == .agent {
            switch message.kind {
            case .prose, .thought, .unsupported:
                completedAt = max(completedAt ?? message.timestamp, message.timestamp)
            case .toolUse, .terminal, .fileEdit, .permissionRequest, .question:
                return nil
            case .status, .attachment:
                break
            }
        }
        return completedAt
    }
}
