public import Foundation

/// One past exchange of a chat that opened before it can resume (cx-khns1): acpmux's
/// `_acpmux/chat_transcript` read it from the chat's own transcript. The page draws these
/// read-only where a new chat's hero would be, until the chat has a session.
public nonisolated struct AgentPanePastTurn: Codable, Sendable, Equatable {
    public var prompt: String
    public var answer: String
    /// When the prompt was sent and the answer last written (ms since the epoch), when recorded.
    public var promptAt: Double?
    public var answerAt: Double?

    public init(prompt: String, answer: String, promptAt: Double? = nil, answerAt: Double? = nil) {
        self.prompt = prompt
        self.answer = answer
        self.promptAt = promptAt
        self.answerAt = answerAt
    }

    /// The turns of a `_acpmux/chat_transcript` result; malformed turns are skipped.
    public static func turns(result: [String: Any]) -> [AgentPanePastTurn] {
        (result["turns"] as? [[String: Any]] ?? []).compactMap { turn in
            guard let prompt = turn["prompt"] as? String else { return nil }
            return AgentPanePastTurn(prompt: prompt, answer: turn["answer"] as? String ?? "",
                                     promptAt: (turn["promptAt"] as? NSNumber)?.doubleValue,
                                     answerAt: (turn["answerAt"] as? NSNumber)?.doubleValue)
        }
    }
}

/// The app's reader of a device-wide chat's past turns (cx-khns1).
extension AgentPanePastTurn {
    /// Reads a chat's past turns by its index key (`harness:id`); set at launch. Empty when the
    /// daemon cannot read them.
    @MainActor public static var reader: (@MainActor (_ chat: String) async -> [AgentPanePastTurn])?

    /// The past turns a new chat shows for the seed's `pastChat`, nil for none.
    @MainActor static func turns(of chat: String?) async -> [AgentPanePastTurn]? {
        guard let chat, let read = reader else { return nil }
        let turns = await read(chat)
        return turns.isEmpty ? nil : turns
    }
}
