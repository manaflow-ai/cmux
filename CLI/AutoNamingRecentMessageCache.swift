import Foundation

struct AutoNamingRecentMessageCache: Sendable {
    let maxMessages: Int
    let maxMessageCharacters: Int

    func appending(
        _ messages: [AutoNamingTranscriptMessage],
        to recentMessages: [AutoNamingTranscriptMessage]
    ) -> (messages: [AutoNamingTranscriptMessage], insertedCount: Int) {
        var recent = recentMessages
        var seen = Set(recent.map(dedupKey))
        var eventSeen = Set<String>()
        var insertedCount = 0
        for message in messages {
            guard let normalized = normalizedMessage(message) else { continue }
            let key = dedupKey(normalized)
            guard eventSeen.insert(key).inserted else { continue }
            guard seen.insert(key).inserted else { continue }
            insertedCount += 1
            recent.append(normalized)
        }
        if recent.count > maxMessages {
            recent.removeFirst(recent.count - maxMessages)
        }
        return (recent, insertedCount)
    }

    private func normalizedMessage(_ message: AutoNamingTranscriptMessage) -> AutoNamingTranscriptMessage? {
        let role = message.role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard role == "user" || role == "assistant" else { return nil }
        let text = normalizedSingleLine(message.text)
        guard !text.isEmpty else { return nil }
        return AutoNamingTranscriptMessage(role: role, text: truncated(text, maxLength: maxMessageCharacters))
    }

    private func dedupKey(_ message: AutoNamingTranscriptMessage) -> String {
        "\(message.role)\u{1F}\(message.text)"
    }

    private func normalizedSingleLine(_ value: String) -> String {
        let collapsed = value.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func truncated(_ value: String, maxLength: Int) -> String {
        guard value.count > maxLength else { return value }
        let index = value.index(value.startIndex, offsetBy: max(0, maxLength - 1))
        return String(value[..<index]) + "…"
    }
}
