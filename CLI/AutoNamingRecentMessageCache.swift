import Foundation

struct AutoNamingRecentMessageCache: Sendable {
    let maxMessages: Int
    let maxMessageCharacters: Int

    func appending(
        _ messages: [AutoNamingTranscriptMessage],
        batchKey: String?,
        to recentMessages: [AutoNamingTranscriptMessage],
        recentBatchKeys: [String]
    ) -> (messages: [AutoNamingTranscriptMessage], batchKeys: [String], progressCount: Int) {
        let normalizedBatchKey = batchKey.map(normalizedSingleLine).flatMap { $0.isEmpty ? nil : $0 }
        var batchKeys = recentBatchKeys
        if let normalizedBatchKey, batchKeys.contains(normalizedBatchKey) {
            return (recentMessages, batchKeys, 0)
        }
        var recent = recentMessages
        var seen = Set(recent.map(dedupKey))
        var eventSeen = Set<String>()
        var eventMessages: [AutoNamingTranscriptMessage] = []
        for message in messages {
            guard let normalized = normalizedMessage(message) else { continue }
            let key = dedupKey(normalized)
            guard eventSeen.insert(key).inserted else { continue }
            eventMessages.append(normalized)
        }
        let progressCount = eventMessages.count
        for normalized in eventMessages {
            guard seen.insert(dedupKey(normalized)).inserted else { continue }
            recent.append(normalized)
        }
        if recent.count > maxMessages {
            recent.removeFirst(recent.count - maxMessages)
        }
        if let normalizedBatchKey {
            batchKeys.append(normalizedBatchKey)
            if batchKeys.count > maxMessages {
                batchKeys.removeFirst(batchKeys.count - maxMessages)
            }
        }
        return (recent, batchKeys, progressCount)
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
