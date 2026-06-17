import Foundation

enum ChatConversationRunSignal: Sendable {
    case event(ChatSessionEvent)
    case retryPendingTranscript
    case streamEnded
    case overflowed
}

extension ChatConversationRunSignal {
    var isReplayableByHistory: Bool {
        guard case .event(let event) = self else { return false }
        switch event {
        case .appended, .updated:
            return true
        case .stateChanged, .descriptorChanged, .terminalBlocks, .reset, .unknown:
            return false
        }
    }
}
