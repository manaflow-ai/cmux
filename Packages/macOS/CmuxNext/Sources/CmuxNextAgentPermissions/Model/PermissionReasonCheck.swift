import Foundation

/// Whether an agent's reason fits what the person asked for
/// (plans/cmux-next/agent-permissions-DESIGN.md section 4).
///
/// Deterministic and cheap: content words of the reason and of the prompt
/// are compared after lowercasing, stop-word removal and a small suffix
/// strip, and the prompt is also checked against the kind's vocabulary.
/// A false `unclear` costs one gray row on the card; the card never calls a
/// request safe.
///
/// ```swift
/// let check = PermissionReasonCheck(kind: .fullDiskAccess,
///                                   reason: "Read your Mail database to find the invoices",
///                                   prompt: "find the March invoices in my mail")
/// check.verdict // .matches
/// ```
public nonisolated struct PermissionReasonCheck: Sendable, Equatable {
    /// The check's answer; the raw value is the wire name.
    public enum Verdict: String, Sendable, Equatable {
        /// The reason and the prompt share content, or the prompt names work that needs the grant.
        case matches
        /// Nothing links the reason to the prompt: the card shows a warning row.
        case unclear
        /// The request names no prompt of the person.
        case noPrompt = "no_prompt"
        /// The reason is empty or too short to read: the socket refuses the request.
        case noReason = "no_reason"
    }

    /// The shortest reason accepted (characters, after trimming).
    public static let minimumReasonLength = 8

    public let verdict: Verdict
    /// Content words the reason and the prompt share (stems), for diagnostics.
    public let sharedWords: Set<String>

    public init(kind: PermissionKind, reason: String, prompt: String?) {
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= Self.minimumReasonLength else {
            verdict = .noReason
            sharedWords = []
            return
        }
        guard let prompt, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            verdict = .noPrompt
            sharedWords = []
            return
        }
        let reasonWords = contentStems(trimmed)
        let promptWords = contentStems(prompt)
        let shared = reasonWords.intersection(promptWords)
        sharedWords = shared
        let vocabulary = kind.vocabulary
        let promptNeedsGrant = promptWords.contains { word in vocabulary.contains { word.hasPrefix($0) } }
        verdict = shared.isEmpty && !promptNeedsGrant ? .unclear : .matches
    }
}

/// Lowercase content-word stems of `text`: letters and digits, stop words
/// dropped, a small suffix strip so "folders" and "folder" meet.
private nonisolated func contentStems(_ text: String) -> Set<String> {
    let words = text.lowercased().split { !$0.isLetter && !$0.isNumber }
    var stems = Set<String>()
    for word in words where word.count > 1 && !stopWords.contains(String(word)) {
        stems.insert(stem(String(word)))
    }
    return stems
}

private nonisolated func stem(_ word: String) -> String {
    for suffix in ["ing", "ies", "es", "ed", "s", "e", "y"] where word.count > suffix.count + 3 && word.hasSuffix(suffix) {
        return String(word.dropLast(suffix.count))
    }
    return word
}

/// Words that carry no request content (articles, pronouns, request filler,
/// and the permission words every reason has).
private nonisolated let stopWords: Set<String> = [
    "a", "an", "the", "and", "or", "but", "to", "of", "in", "on", "at", "for", "from", "with", "by", "as", "is", "are", "be",
    "it", "its", "this", "that", "these", "those", "i", "me", "my", "you", "your", "we", "our", "us", "they", "them", "so",
    "can", "could", "would", "should", "will", "need", "needs", "want", "wants", "please", "do", "does", "then", "now",
    "all", "any", "some", "just", "also", "into", "out", "up", "if", "can't", "not", "no", "get", "make", "let", "lets",
    "cmux", "access", "permission", "permissions", "allow", "grant", "macos", "mac", "system", "settings", "able", "order",
]
