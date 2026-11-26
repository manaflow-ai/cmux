import Foundation

extension String {
    /// Words every row's line means, so a subtitle made of them and the title's words says nothing new.
    nonisolated private static let restatingWords: Set<String> = ["a", "an", "the", "open", "new", "find", "search", "show", "start", "create"]

    /// Whether this subtitle only restates `title` ("New Browser Tab" / "Open a browser tab"): every word it has is
    /// the title's or one every row means. Such a line is narration (design/menus.md) and the row drops it.
    nonisolated func restatesTitle(_ title: String) -> Bool {
        let titleWords = Set(title.paletteWords)
        let said = paletteWords
        return !said.isEmpty && said.allSatisfy { titleWords.contains($0) || Self.restatingWords.contains($0) }
    }

    /// Lowercased letter-and-digit runs, a trailing plural "s" dropped from words past three letters.
    private nonisolated var paletteWords: [String] {
        lowercased().split { !($0.isLetter || $0.isNumber) }.map { word in
            word.count > 3 && word.hasSuffix("s") ? String(word.dropLast()) : String(word)
        }
    }
}
