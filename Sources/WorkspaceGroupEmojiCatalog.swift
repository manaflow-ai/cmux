enum WorkspaceGroupEmojiCatalog {
    private static let emojis = [
        "🚀", "💻", "🧠", "⚙️", "🔥", "✅", "📁", "🧪", "🎯", "✨", "⚡️", "⭐️",
        "🔧", "📌", "📝", "🔍", "🎨", "🧩", "📦", "🌐", "🔒", "💬", "🏁", "📊",
        "🛠️", "🧰", "📣", "💡", "🕹️", "🧵", "🪄", "🧱", "📎", "🗂️", "📚", "🔬"
    ]

    static func matching(query rawQuery: String) -> [String] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return emojis }
        if let emoji = RenderableSystemSymbol.normalizedEmoji(query) {
            return [emoji] + emojis.filter { $0 != emoji }
        }
        return emojis.filter { $0.localizedCaseInsensitiveContains(query) }
    }
}
