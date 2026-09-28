import Foundation

/// Light cleanup for dictated text headed to an agent prompt.
///
/// Removes spoken English fillers ("um", "uh", ...) and tidies the
/// punctuation they leave behind. It never rewrites other words, and keeps
/// the original spacing and line breaks, so what the user said is what the
/// agent reads. Applied per finalized segment; each call is independent.
///
/// ```swift
/// "um so, uh, fix the build".removingDictationFillers  // "so, fix the build"
/// ```
extension String {
    /// Fillers removed as whole words, case-insensitively. Words that are
    /// also units or real words ("mm", "er", "ah") are left alone.
    static let dictationFillers: Set<String> = [
        "um", "umm", "uh", "uhh", "uhm", "erm", "hmm", "mhm",
    ]

    /// This text with fillers removed; empty when the segment was only
    /// fillers.
    public var removingDictationFillers: String {
        let text = self
        // Alternating runs: each word keeps the whitespace that preceded it.
        var pieces: [(space: Substring, word: Substring)] = []
        var index = text.startIndex
        while index < text.endIndex {
            let wordStart = text[index...].firstIndex { !$0.isWhitespace } ?? text.endIndex
            let wordEnd = text[wordStart...].firstIndex(where: \.isWhitespace) ?? text.endIndex
            pieces.append((text[index..<wordStart], text[wordStart..<wordEnd]))
            index = wordEnd
        }

        var kept: [(space: Substring, word: String)] = []
        var removedAny = false
        for (offset, piece) in pieces.enumerated() {
            let bare = piece.word.trimmingCharacters(in: .punctuationCharacters).lowercased()
            // "20 um" is more likely a misheard unit than a filler; keep it.
            let followsNumber = offset > 0 && pieces[offset - 1].word.last?.isNumber == true
            guard Self.dictationFillers.contains(bare), !followsNumber else {
                kept.append((piece.space, String(piece.word)))
                continue
            }
            removedAny = true
            // Keep sentence punctuation that trailed the filler ("uh." ends a
            // sentence) by moving it onto the previous word.
            let trailing = piece.word.drop { !$0.isPunctuation }.filter { ".?!".contains($0) }
            if !trailing.isEmpty, let last = kept.popLast() {
                var word = last.word
                while word.last == "," { word.removeLast() }
                kept.append((last.space, word + trailing))
            }
        }
        guard removedAny else { return text }
        guard !kept.isEmpty else { return "" }

        // The first kept word takes the segment's original leading space.
        kept[0].space = pieces[0].space
        // A leading filler often leaves a dangling comma: "um, so" -> "so".
        while kept[0].word.first == "," { kept[0].word.removeFirst() }
        // "Um, let's go." should still start with a capital, but only for
        // prose; "Um, git status" stays lowercase.
        let isProse = kept.last.map { ".?!".contains($0.word.last ?? " ") } ?? false
        if isProse, text.first(where: { !$0.isWhitespace })?.isUppercase == true,
           kept[0].word.first?.isLowercase == true {
            kept[0].word = kept[0].word.prefix(1).uppercased() + kept[0].word.dropFirst()
        }
        return kept
            .map { String($0.space) + $0.word }
            .joined()
            .replacingOccurrences(of: " ,", with: ",")
    }
}

extension Locale {
    /// Whether filler cleanup applies to dictation in this locale. The
    /// filler list is English: "um" is an article in Portuguese, for example.
    public var supportsDictationFillerCleanup: Bool {
        language.languageCode == .english
    }
}
