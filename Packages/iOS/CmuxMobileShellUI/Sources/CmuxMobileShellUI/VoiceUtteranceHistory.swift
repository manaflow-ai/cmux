#if os(iOS)
import Foundation

/// Bounded in-memory Voice Mode utterance history.
struct VoiceUtteranceHistory: Equatable {
    private(set) var utterances: [VoiceUtterance]
    let capacity: Int

    init(utterances: [VoiceUtterance] = [], capacity: Int = 50) {
        precondition(capacity > 0)
        self.utterances = Array(utterances.suffix(capacity))
        self.capacity = capacity
    }

    @discardableResult
    mutating func appendFinal(text: String, timestamp: Date = Date(), id: UUID = UUID()) -> UUID {
        let utterance = VoiceUtterance(id: id, text: text, timestamp: timestamp, status: .sending)
        utterances.append(utterance)
        trimToCapacity()
        return id
    }

    mutating func beginSending(id: UUID) -> Bool {
        guard let index = utterances.firstIndex(where: { $0.id == id }),
              !utterances[index].status.isSending else {
            return false
        }
        utterances[index].status = .sending
        return true
    }

    mutating func markSent(id: UUID, targetTitle: String) {
        guard let index = utterances.firstIndex(where: { $0.id == id }) else { return }
        utterances[index].status = .sent(targetTitle: targetTitle)
    }

    mutating func markFailed(id: UUID, message: String, isTargetChanged: Bool) {
        guard let index = utterances.firstIndex(where: { $0.id == id }) else { return }
        utterances[index].status = .failed(message: message, isTargetChanged: isTargetChanged)
    }

    func utterance(id: UUID) -> VoiceUtterance? {
        utterances.first(where: { $0.id == id })
    }

    private mutating func trimToCapacity() {
        guard utterances.count > capacity else { return }
        utterances.removeFirst(utterances.count - capacity)
    }
}
#endif
