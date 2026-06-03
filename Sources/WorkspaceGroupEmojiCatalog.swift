enum WorkspaceGroupEmojiCatalog {
    private static let commonEmoji = [
        "🚀", "💻", "🧠", "⚙️", "🔥", "✅", "📁", "🧪", "🎯", "✨", "⚡️", "⭐️",
        "🔧", "📌", "📝", "🔍", "🎨", "🧩", "📦", "🌐", "🔒", "💬", "🏁", "📊",
        "🛠️", "🧰", "📣", "💡", "🕹️", "🧵", "🪄", "🧱", "📎", "🗂️", "📚", "🔬"
    ]

    private static let emojis = commonEmoji + generatedEmoji.filter { !commonEmoji.contains($0) }

    static func matching(query rawQuery: String) -> [String] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return emojis }
        if let emoji = RenderableSystemSymbol.normalizedEmoji(query) {
            return [emoji] + emojis.filter { $0 != emoji }
        }
        return emojis.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    private static let generatedEmoji: [String] = {
        var values: [String] = []
        var seen = Set<String>()
        for range in emojiScalarRanges {
            for value in range {
                guard let scalar = UnicodeScalar(value) else { continue }
                let emoji = String(Character(scalar))
                guard RenderableSystemSymbol.normalizedEmoji(emoji) != nil,
                      !seen.contains(emoji) else { continue }
                seen.insert(emoji)
                values.append(emoji)
            }
        }
        return values
    }()

    private static let emojiScalarRanges: [ClosedRange<Int>] = [
        0x203C ... 0x3299,
        0x1F000 ... 0x1FAFF
    ]
}
