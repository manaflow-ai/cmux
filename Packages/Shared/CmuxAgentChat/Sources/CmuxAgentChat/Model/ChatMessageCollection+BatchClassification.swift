import Foundation

/// Derived transcript-batch classifications shared by Mac capture and chat consumers.
public extension Collection where Element == ChatMessage {
    /// Whether the batch carries committed agent prose that settles live preview.
    var containsAgentProse: Bool {
        contains { message in
            guard message.role == .agent else { return false }
            if case .prose = message.kind { return true }
            return false
        }
    }

    /// Latest agent timestamp when the batch contains no unfinished agent work.
    var completedAssistantTurnTimestamp: Date? {
        guard !isEmpty else { return nil }
        guard !contains(where: { message in
            guard message.role == .agent else { return false }
            switch message.kind {
            case .toolUse, .terminal, .fileEdit, .permissionRequest, .question:
                return true
            case .prose, .thought, .status, .attachment, .unsupported:
                return false
            }
        }) else { return nil }
        return lazy.filter { $0.role == .agent }.compactMap { message in
            switch message.kind {
            case .prose, .thought, .unsupported:
                return message.timestamp
            case .toolUse, .terminal, .fileEdit, .permissionRequest, .question, .status, .attachment:
                return nil
            }
        }
        .max()
    }
}
