#if os(iOS)
import Foundation

/// A finalized Voice Mode utterance and its send status.
struct VoiceUtterance: Equatable, Identifiable, Sendable {
    let id: UUID
    let text: String
    let timestamp: Date
    var status: VoiceUtteranceStatus

    init(
        id: UUID = UUID(),
        text: String,
        timestamp: Date = Date(),
        status: VoiceUtteranceStatus
    ) {
        self.id = id
        self.text = text
        self.timestamp = timestamp
        self.status = status
    }
}

enum VoiceUtteranceStatus: Equatable, Sendable {
    case sending
    case sent(targetTitle: String)
    case failed(message: String, isTargetChanged: Bool)

    var isSending: Bool {
        if case .sending = self {
            return true
        }
        return false
    }
}
#endif
