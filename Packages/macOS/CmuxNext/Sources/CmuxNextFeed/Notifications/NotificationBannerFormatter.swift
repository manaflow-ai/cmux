package import Foundation

/// What a system banner says, built from what the app knows for sure (where) and what the poster
/// said (state and message): title = `workspace › tab [· machine]`, subtitle = the state headline
/// (`Claude finished`, `Needs input`) and the poster's subtitle, body = the message as plain text.
/// The app writes the title, so a terminal program cannot pose as another terminal.
/// (~/fun/cmux-prompts/logs/notifications-DESIGN.md)
package struct NotificationBannerFormatter {
    /// The body's length limit: about four banner lines.
    package var maxBodyCharacters = 240
    /// A workspace or tab name's length limit in the title.
    package var maxNameCharacters = 40

    /// The banner for a notification whose headline is `headline` (the daemon's title, an OSC
    /// 7501 alert's localized title, a burst digest's count). `workspace` nil (no tab in the
    /// store) keeps the headline as the title. `plain` false keeps the body's lines as given
    /// (an approval's command).
    package func content(headline: String, posterSubtitle: String?, body: String, workspace: String?, tab: String?,
                 host: String?, plain: Bool = true) -> NotificationBannerContent {
        let headline = headline.trimmingCharacters(in: .whitespacesAndNewlines)
        let poster = posterSubtitle.flatMap(nonEmpty)
        let text = plain ? plainText(body) : body
        guard let workspace = workspace.flatMap(nonEmpty) else {
            return NotificationBannerContent(title: nonEmpty(headline) ?? tab.flatMap(nonEmpty) ?? "cmux", subtitle: poster, body: text)
        }
        let tabName = tab.flatMap(nonEmpty).flatMap { $0 == workspace ? nil : $0 }
        var title = clip(workspace, to: maxNameCharacters)
        if let tabName { title += " › " + clip(tabName, to: maxNameCharacters) }
        if let host = host.flatMap(nonEmpty) { title += " · " + host }
        var state = headline
        // "Fix login needs input" in tab "Fix login": the title already names the chat.
        if let tabName, state.count > tabName.count + 1, state.hasPrefix(tabName + " ") {
            let rest = state.dropFirst(tabName.count + 1)
            state = rest.prefix(1).uppercased() + rest.dropFirst()
        }
        let subtitle = [nonEmpty(state), poster].compactMap { $0 }.joined(separator: " · ")
        return NotificationBannerContent(title: title, subtitle: subtitle.isEmpty ? nil : subtitle, body: text)
    }

    /// `markdown` as banner text: no heading, quote or emphasis marks, links and images as their
    /// text, code fences dropped (their code kept), list items as bullets, blank lines removed,
    /// cut on a word to ``maxBodyCharacters`` with an ellipsis.
    package func plainText(_ markdown: String) -> String {
        var lines: [String] = []
        for raw in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") || line.isEmpty { continue }
            line = line.replacing(/^#{1,6}\s+/, with: "")
            line = line.replacing(/^(>\s?)+/, with: "")
            line = line.replacing(/^[-*+]\s+/, with: "• ")
            line = line.replacing(/!\[([^\]]*)\]\([^)]*\)/) { String($0.output.1) }
            line = line.replacing(/\[([^\]]+)\]\([^)]*\)/) { String($0.output.1) }
            line = line.replacing(/(\*\*|__)(\S(?:.*?\S)?)\1/) { String($0.output.2) }
            // Single-star emphasis, not `2*3*4`: the opening star follows no word character.
            line = line.replacing(/(^|[^\w*])\*(\S(?:[^*]*?\S)?)\*(?![\w*])/) { $0.output.1 + $0.output.2 }
            line = line.replacing(/~~(.+?)~~/) { String($0.output.1) }
            line = line.replacing("`", with: "")
            line = line.trimmingCharacters(in: .whitespaces)
            if !line.isEmpty { lines.append(line) }
        }
        return clip(lines.joined(separator: "\n"), to: maxBodyCharacters, onWord: true)
    }

    /// `text` cut to `limit` characters with "…" (the ellipsis counts), on the last space
    /// within the final 30 characters when `onWord`.
    private func clip(_ text: String, to limit: Int, onWord: Bool = false) -> String {
        guard text.count > limit, limit > 1 else { return text }
        var cut = text.prefix(limit - 1)
        if onWord, let space = cut.lastIndex(where: \.isWhitespace), cut.distance(from: space, to: cut.endIndex) < 30 {
            cut = cut[..<space]
        }
        return cut.trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    package init(maxBodyCharacters: Int = 240, maxNameCharacters: Int = 40) {
        self.maxBodyCharacters = maxBodyCharacters
        self.maxNameCharacters = maxNameCharacters
    }
}

/// `text` without surrounding whitespace, nil when nothing is left.
private func nonEmpty(_ text: String) -> String? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}
