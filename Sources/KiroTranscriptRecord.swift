import Foundation

/// A persisted Kiro CLI message (the on-disk format differs from ACP wire notifications).
struct KiroTranscriptRecord: Sendable {
    let role: SessionTranscriptRole
    let text: String

    init?(object: [String: Any]) {
        switch object["kind"] as? String {
        case "UserMessage": role = .user
        case "AssistantMessage": role = .assistant
        default: return nil
        }
        guard let data = object["data"] as? [String: Any],
              let content = data["content"] as? [[String: Any]] else { return nil }
        // Tool arguments and embedded resources are not conversation text.
        let text = content.compactMap { block -> String? in
            guard block["kind"] as? String == "text" else { return nil }
            return block["data"] as? String
        }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        self.text = text
    }
}
