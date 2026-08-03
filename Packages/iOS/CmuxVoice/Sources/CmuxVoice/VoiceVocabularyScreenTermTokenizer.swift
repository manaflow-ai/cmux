import Foundation

/// Pure tokenizer for automatic Voice Mode vocabulary terms.
public struct VoiceVocabularyScreenTermTokenizer: Sendable {
    /// Creates a tokenizer for visible Mac titles.
    public init() {}

    /// Extracts ordered, unique tokens from visible Mac screen strings.
    public func tokenize(_ values: [String], limit: Int = VoiceVocabularyStore.maxScreenTerms) -> [String] {
        var terms: [String] = []
        var current = ""

        func flush() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            current = ""
            guard trimmed.count >= 3 else { return }
            terms.append(trimmed)
        }

        for value in values {
            for scalar in value.unicodeScalars {
                if CharacterSet.alphanumerics.contains(scalar) || scalar == "_" {
                    current.unicodeScalars.append(scalar)
                } else {
                    flush()
                }
            }
            flush()
        }

        return VoiceVocabularyStore.normalizedTerms(terms, limit: limit)
    }
}
