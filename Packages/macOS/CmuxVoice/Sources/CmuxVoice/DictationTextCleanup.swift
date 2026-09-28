import Foundation

/// Light cleanup for dictated text headed to an agent prompt.
///
/// Removes spoken fillers ("um", "uh", ...) and tidies the whitespace and
/// punctuation they leave behind. It never rewrites words, so what the user
/// said is what the agent reads. Applied per finalized segment; each call is
/// independent.
///
/// ```swift
/// DictationTextCleanup.cleaned("um so, uh, fix the build")  // "so, fix the build"
/// ```
public enum DictationTextCleanup {
    /// Fillers removed as whole words, case-insensitively.
    static let fillers: Set<String> = [
        "um", "umm", "uh", "uhh", "uhm", "erm", "er", "ah", "hmm", "mm", "mhm",
    ]

    /// Returns `text` with fillers removed. Returns an empty string when the
    /// segment was only fillers.
    public static func cleaned(_ text: String) -> String {
        var words: [String] = []
        for token in text.split(whereSeparator: \.isWhitespace) {
            let word = String(token)
            let bare = word.trimmingCharacters(in: .punctuationCharacters).lowercased()
            guard fillers.contains(bare) else {
                words.append(word)
                continue
            }
            // Keep sentence punctuation that trailed the filler ("uh." ends a
            // sentence) by moving it onto the previous word.
            let trailing = word.drop { !$0.isPunctuation }
                .filter { ".?!".contains($0) }
            if !trailing.isEmpty, let last = words.popLast() {
                words.append(last.trimmingCharacters(in: CharacterSet(charactersIn: ",")) + trailing)
            }
        }
        guard var first = words.first else { return "" }
        // A leading filler often leaves a dangling comma: "um, so" -> "so".
        while let head = first.first, head == "," {
            first.removeFirst()
        }
        // "Um, let's go" should still start with a capital.
        if text.first?.isUppercase == true, first.first?.isLowercase == true {
            first = first.prefix(1).uppercased() + first.dropFirst()
        }
        words[0] = first
        return words
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .replacingOccurrences(of: " ,", with: ",")
    }
}
