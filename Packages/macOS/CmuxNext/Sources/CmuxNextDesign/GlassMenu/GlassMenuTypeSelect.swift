import Foundation

/// Typing to jump in a ``GlassMenu``, as in an `NSMenu`: the letters typed within ``timeout`` of each
/// other pick the first row whose title starts with them (case and accents ignored); one letter
/// typed again moves on to the next row starting with it, wrapping.
struct GlassMenuTypeSelect {
    /// The pause (seconds) after which typing starts a new search.
    static let timeout: TimeInterval = 1

    private(set) var typed = ""
    private var lastTime: TimeInterval = -.infinity

    /// The row `characters` typed at `time` (an event's timestamp) picks, or nil when none matches.
    ///
    /// - Parameters:
    ///   - titles: every row's title in order, nil for a row the highlight skips (a separator, a
    ///     disabled row).
    ///   - current: the highlighted row, where a repeated letter continues from.
    mutating func pick(_ characters: String, at time: TimeInterval, titles: [String?], current: Int?) -> Int? {
        let typedNow = Self.fold(characters)
        guard !typedNow.isEmpty else { return nil }
        if time - lastTime > Self.timeout { typed = "" }
        lastTime = time
        typed += typedNow
        let folded = titles.map { $0.map(Self.fold) }
        if let first = typed.first, typed.allSatisfy({ $0 == first }) {
            // One letter, typed once or again: the next row starting with it after the highlight.
            let start = current.map { $0 + 1 } ?? 0
            let order = Array(start..<folded.count) + Array(0..<min(start, folded.count))
            return order.first { folded[$0]?.hasPrefix(String(first)) == true }
        }
        return folded.firstIndex { $0?.hasPrefix(typed) == true }
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}
