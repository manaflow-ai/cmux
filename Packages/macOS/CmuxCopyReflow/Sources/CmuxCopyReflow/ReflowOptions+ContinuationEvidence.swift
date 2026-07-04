import Foundation

extension ReflowOptions {
    /// Width-only lowercase joins are intentionally narrower than command/indent
    /// joins: without indentation, independent log rows can look like prose. Join
    /// only when the surrounding words have a sentence-continuation shape.
    func hasProseContinuationEvidence(
        previous: String,
        current: String,
        commonIndent: Int,
        alreadyJoined: Bool
    ) -> Bool {
        if commonIndent > 0 || alreadyJoined { return true }
        if let word = lastWord(in: previous), Self.continuationTailWords.contains(word) {
            return true
        }
        if let word = firstWord(in: current), Self.continuationHeadWords.contains(word) {
            return true
        }
        return false
    }

    /// Common starts for terminal log/status records. These are left as separate
    /// rows unless a stronger continuation-indent or command-token signal exists.
    func startsIndependentRecord(_ current: String, after previous: String) -> Bool {
        guard let currentFirst = firstWord(in: current) else { return false }
        if Self.recordStartWords.contains(currentFirst) { return true }
        return currentFirst == firstWord(in: previous)
    }

    /// Option/help rows are line-oriented records even when they are long and
    /// start with command-looking tokens.
    func startsOptionLikeRow(_ s: String) -> Bool {
        let trimmed = s.trimmingLeadingWhitespaceForReflow()
        if trimmed.hasPrefix("--") {
            let rest = trimmed.dropFirst(2)
            return rest.first?.isLetter == true
        }
        if trimmed.hasPrefix("-") {
            let rest = trimmed.dropFirst()
            return rest.first?.isLetter == true
        }
        return false
    }

    static let continuationTailWords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "because", "been", "being",
        "but", "by", "can", "could", "did", "do", "does", "for", "from", "had",
        "has", "have", "if", "in", "into", "is", "less", "may", "might", "more",
        "most", "must", "not", "of", "on", "onto", "or", "over", "should", "so",
        "than", "that", "the", "then", "to", "too", "under", "very", "was",
        "were", "when", "where", "which", "while", "who", "whose", "will",
        "with", "within", "without", "would"
    ]

    static let continuationHeadWords: Set<String> = [
        "and", "as", "because", "but", "for", "if", "in", "nor", "or", "so",
        "than", "that", "then", "though", "to", "unless", "until", "when",
        "where", "which", "while", "who", "whose", "yet"
    ]

    static let recordStartWords: Set<String> = [
        "created", "debug", "deleted", "done", "error", "failed", "failure",
        "fatal", "info", "notice", "ok", "processing", "queued", "retrying",
        "running", "skipping", "started", "starting", "stopped", "stopping",
        "success", "trace", "updated", "warn", "warning"
    ]

    func firstWord(in s: String) -> String? {
        let trimmed = s.trimmingLeadingWhitespaceForReflow()
        var end = trimmed.startIndex
        while end < trimmed.endIndex,
              trimmed[end].isLetter || trimmed[end].isNumber {
            end = trimmed.index(after: end)
        }
        guard end > trimmed.startIndex else { return nil }
        return String(trimmed[..<end]).lowercased()
    }

    func lastWord(in s: String) -> String? {
        var end = s.endIndex
        while end > s.startIndex {
            let previous = s.index(before: end)
            if s[previous].isLetter || s[previous].isNumber {
                break
            }
            end = previous
        }
        guard end > s.startIndex else { return nil }

        var start = end
        while start > s.startIndex {
            let previous = s.index(before: start)
            if !s[previous].isLetter && !s[previous].isNumber {
                break
            }
            start = previous
        }
        return String(s[start..<end]).lowercased()
    }
}

private extension String {
    func trimmingLeadingWhitespaceForReflow() -> String {
        String(drop { $0 == " " || $0 == "\t" })
    }
}
