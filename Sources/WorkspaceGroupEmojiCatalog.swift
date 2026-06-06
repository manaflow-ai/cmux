import Foundation

enum WorkspaceGroupEmojiCatalog {
    /// A small, hand-picked set rendered instantly while the full catalog builds off the main thread.
    static let commonEmoji = [
        "🚀", "💻", "🧠", "⚙️", "🔥", "✅", "📁", "🧪", "🎯", "✨", "⚡️", "⭐️",
        "🔧", "📌", "📝", "🔍", "🎨", "🧩", "📦", "🌐", "🔒", "💬", "🏁", "📊",
        "🛠️", "🧰", "📣", "💡", "🕹️", "🧵", "🪄", "🧱", "📎", "🗂️", "📚", "🔬"
    ]

    /// The full de-duplicated browse catalog, scanned from the emoji scalar ranges exactly once.
    ///
    /// Building this walks ~15k Unicode scalars, so it must never run inside a SwiftUI `body`.
    /// Access it from a background task (see ``WorkspaceGroupIconPickerView``) so the one-time scan
    /// stays off the main thread; the value is cached for every later read.
    static let allEmoji: [String] = buildAllEmoji()

    /// The emoji to surface for a picker query.
    ///
    /// An empty query browses the whole `catalog`. A single-emoji query echoes just that emoji.
    /// Any other query (for example an SF Symbol name) yields no emoji.
    static func browseResults(query rawQuery: String, catalog: [String]) -> [String] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return catalog }
        if let emoji = RenderableSystemSymbol.normalizedEmoji(query) {
            return [emoji]
        }
        return []
    }

    private static func buildAllEmoji() -> [String] {
        var values: [String] = []
        var seen = Set<String>()

        for emoji in commonEmoji where seen.insert(emoji).inserted {
            values.append(emoji)
        }

        for range in emojiScalarRanges {
            for value in range {
                guard let scalar = UnicodeScalar(value) else { continue }
                let emoji = String(Character(scalar))
                guard RenderableSystemSymbol.normalizedEmoji(emoji) != nil,
                      seen.insert(emoji).inserted else { continue }
                values.append(emoji)
            }
        }

        return values
    }

    private static let emojiScalarRanges: [ClosedRange<Int>] = [
        0x203C ... 0x3299,
        0x1F000 ... 0x1FAFF
    ]
}
