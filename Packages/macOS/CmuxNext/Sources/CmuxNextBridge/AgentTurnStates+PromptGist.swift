import Foundation

extension AgentTurnStates {
    /// The line that names a chat in a title or first prompt, as acpmux titles it
    /// (cmux-tui `hub/titles.rs` `prompt_gist`, 2026-10-20: every Chief subagent tab read
    /// "Agent" or "<chat>"). Leading `<tag>…</tag>` context blocks (a Chief's `<chat>` view)
    /// are skipped, and so are a label line ("Your task:") and a `Group:` header; a `Title:`
    /// header names the chat. Nil when nothing is left, also for a block cut off before it
    /// closes (acpmux shortens prompts): its first line is no title.
    ///
    /// ```swift
    /// AgentTurnStates.promptGist("<chat>…</chat>Your task:\nTitle: ACP agent tab names") // "ACP agent tab names"
    /// AgentTurnStates.promptGist("<chat> 0+512|user: merge…")                          // nil
    /// ```
    public nonisolated static func promptGist(_ text: String) -> String? {
        promptGist(text, requiringTitleHeader: false)
    }

    /// Workspace names accept only a leading Title header, after context blocks and labels.
    public nonisolated static func promptGist(_ text: String, requiringTitleHeader: Bool) -> String? {
        guard let body = strippingLeadingBlocks(text) else { return nil }
        for raw in body.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || isLabel(line) || headerValue(line, key: "group") != nil { continue }
            return headerValue(line, key: "title") ?? (requiringTitleHeader ? nil : line)
        }
        return nil
    }
}

/// `text` without the `<tag>…</tag>` blocks it opens with; nil when one never closes.
nonisolated private func strippingLeadingBlocks(_ text: String) -> Substring? {
    var rest = Substring(text).drop { $0.isWhitespace }
    while let tag = openingTag(rest) {
        guard let close = rest.range(of: "</\(tag)>") else { return nil }
        rest = rest[close.upperBound...].drop { $0.isWhitespace }
    }
    return rest
}

/// The tag name `text` opens with (`<chat>`, `<context kind="x">`), if it opens with one.
nonisolated private func openingTag(_ text: Substring) -> Substring? {
    guard text.first == "<" else { return nil }
    let inner = text.dropFirst()
    let name = inner.prefix { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    guard let first = name.first, first.isLetter else { return nil }
    let after = inner.dropFirst(name.count)
    guard after.first == ">" || after.first == " ", after.contains(">") else { return nil }
    return name
}

/// A short line that only introduces what follows ("Your task:").
nonisolated private func isLabel(_ line: String) -> Bool {
    line.hasSuffix(":") && line.split(whereSeparator: \.isWhitespace).count <= 3
}

/// The value of a `Key: value` header line, if `line` is one.
nonisolated private func headerValue(_ line: String, key: String) -> String? {
    guard let colon = line.firstIndex(of: ":") else { return nil }
    let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
    guard line[..<colon].trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(key) == .orderedSame, !value.isEmpty
    else { return nil }
    return value
}
