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
        guard let finalProse = lazy.filter({ $0.role == .agent }).filter({ message in
            if case .prose = message.kind { return true }
            return false
        }).max(by: { $0.seq < $1.seq }) else {
            return nil
        }
        guard !contains(where: { message in
            guard message.role == .agent else { return false }
            switch message.kind {
            case .toolUse(let toolUse):
                return toolUse.status == .running || message.seq > finalProse.seq
            case .terminal(let terminal):
                return terminal.isRunning || message.seq > finalProse.seq
            case .fileEdit, .thought, .unsupported:
                return message.seq > finalProse.seq
            case .permissionRequest, .question:
                return true
            case .prose, .status, .attachment:
                return false
            }
        }) else { return nil }
        return finalProse.timestamp
    }
}
