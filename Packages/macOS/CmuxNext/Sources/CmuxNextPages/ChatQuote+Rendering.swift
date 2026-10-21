public import Foundation

nonisolated extension ChatQuote {
    /// The card's title: the source's last path component and the line range, `README.md · L12–18`.
    /// A web source shows its host and path (`example.com/docs/page`).
    public var title: String {
        guard let lines else { return sourceName }
        let range = lines.lowerBound == lines.upperBound ? "L\(lines.lowerBound)" : "L\(lines.lowerBound)–\(lines.upperBound)"
        return "\(sourceName) · \(range)"
    }

    /// The text a chat sends for this quote: a Markdown block quote headed by the bold ``title``,
    /// then the comment after a blank line.
    ///
    /// ```
    /// > **README.md · L3–4**
    /// > first line
    /// > second line
    ///
    /// Is this right?
    /// ```
    public var markdown: String {
        var body = quoted
        while body.hasSuffix("\n") || body.hasSuffix("\r") { body.removeLast() }
        let quotedLines = body.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let text = line.hasSuffix("\r") ? String(line.dropLast()) : String(line)
            return text.isEmpty ? ">" : "> " + text
        }
        var out = (["> **\(title)**"] + quotedLines).joined(separator: "\n")
        let note = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        if !note.isEmpty { out += "\n\n" + note }
        return out
    }

    private var sourceName: String {
        if let url = URL(string: source), let scheme = url.scheme, scheme == "http" || scheme == "https", let host = url.host() {
            return host + url.path()
        }
        return (source as NSString).lastPathComponent
    }
}
