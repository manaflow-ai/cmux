import Foundation

enum WorkspaceGroupEmojiCatalog {
    private static let commonEmoji = [
        "🚀", "💻", "🧠", "⚙️", "🔥", "✅", "📁", "🧪", "🎯", "✨", "⚡️", "⭐️",
        "🔧", "📌", "📝", "🔍", "🎨", "🧩", "📦", "🌐", "🔒", "💬", "🏁", "📊",
        "🛠️", "🧰", "📣", "💡", "🕹️", "🧵", "🪄", "🧱", "📎", "🗂️", "📚", "🔬"
    ]

    static func matching(query rawQuery: String, limit: Int) -> (emojis: [String], hasMore: Bool) {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return pageAllEmoji(limit: limit)
        }
        if let emoji = RenderableSystemSymbol.normalizedEmoji(query) {
            return ([emoji], false)
        }
        return ([], false)
    }

    private static func pageAllEmoji(limit: Int) -> (emojis: [String], hasMore: Bool) {
        let cappedLimit = max(limit, 0)
        guard cappedLimit > 0 else { return ([], true) }
        var values: [String] = []
        values.reserveCapacity(cappedLimit)
        var seen = Set<String>()

        for emoji in commonEmoji {
            guard !seen.contains(emoji) else { continue }
            seen.insert(emoji)
            values.append(emoji)
            if values.count >= cappedLimit {
                return (values, true)
            }
        }

        for range in emojiScalarRanges {
            for value in range {
                guard let scalar = UnicodeScalar(value) else { continue }
                let emoji = String(Character(scalar))
                guard RenderableSystemSymbol.normalizedEmoji(emoji) != nil,
                      !seen.contains(emoji) else { continue }
                seen.insert(emoji)
                values.append(emoji)
                if values.count >= cappedLimit {
                    return (values, true)
                }
            }
        }

        return (values, false)
    }

    private static let emojiScalarRanges: [ClosedRange<Int>] = [
        0x203C ... 0x3299,
        0x1F000 ... 0x1FAFF
    ]
}
