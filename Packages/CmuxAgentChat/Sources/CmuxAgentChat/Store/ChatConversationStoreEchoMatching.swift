extension ChatConversationStore {
    /// Parses the monotonic counter from a pending row id (`local-<n>`), used
    /// to order sends for stale-delivered eviction.
    static func pendingCounter(_ id: String) -> Int? {
        guard let dash = id.lastIndex(of: "-") else { return nil }
        return Int(id[id.index(after: dash)...])
    }

    /// Whether an echoed user line is Claude Code's bracketed-paste
    /// placeholder ("[Pasted text #1 +12 lines]").
    static func isPastePlaceholder(_ text: String) -> Bool {
        text.wholeMatch(of: /\[Pasted text #\d+( \+\d+ lines)?\]/) != nil
    }

    /// Matches the prompt when Claude echoes it with a short, non-spaced
    /// prefix left behind in the terminal line editor.
    static func echoedTextHasShortStalePrefix(_ echoed: String, pendingText: String) -> Bool {
        let pending = pendingText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pending.isEmpty,
              echoed != pending,
              echoed.hasSuffix(pending) else { return false }
        let prefix = echoed.dropLast(pending.count)
        guard !prefix.isEmpty, prefix.count <= 8 else { return false }
        return !prefix.contains { character in
            character.isWhitespace || character.isNewline
        }
    }
}
