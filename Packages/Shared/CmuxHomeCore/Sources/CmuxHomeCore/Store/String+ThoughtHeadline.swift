import Foundation

/// The headline of one of the Chief's thoughts: what its running indicator shows as progress narration.
///
/// The live book publishes this, not the whole thought, so a streamed thought token changes the
/// store's live state only when the line a person sees changes.
extension String {
    /// Most characters a thought's headline keeps.
    public static let thoughtHeadlineLimit = 72

    /// This thought's headline: its last bold heading line ("**Checking the tests**", how Claude and
    /// Codex title their reasoning summaries), else its last sentence, as plain text of at most
    /// ``thoughtHeadlineLimit`` characters. Nil for a thought with no words.
    public var thoughtHeadline: String? {
        // A line of only rule marks (`*****`, `---`, `* * *`) has no words: it neither heads the
        // thought nor ends it, so a heading above it still names the thought.
        let lines = split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in line.contains { !"*-_".contains($0) && !$0.isWhitespace } }
        let heading = lines.last { $0.count > 4 && $0.hasPrefix("**") && $0.hasSuffix("**") }
        let raw: String
        if let heading {
            raw = String(heading.dropFirst(2).dropLast(2))
        } else if let last = lines.last {
            raw = last.lastSentence
        } else {
            return nil
        }
        let plain = raw.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "*_#> ").union(.whitespaces))
        guard !plain.isEmpty else { return nil }
        guard plain.count > Self.thoughtHeadlineLimit else { return plain }
        return String(plain.prefix(Self.thoughtHeadlineLimit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// The last sentence of this line (after its last ". ", "! " or "? "), or the line.
    private var lastSentence: String {
        let trimmed = trimmingCharacters(in: .whitespaces)
        let body = trimmed.last.map { ".!?".contains($0) } == true ? String(trimmed.dropLast()) : trimmed
        // After the last ". ", then the last "! " after it, then the last "? ": after the last end of any kind.
        var rest = body
        for end in [". ", "! ", "? "] {
            if let range = rest.range(of: end, options: .backwards) { rest = String(rest.suffix(from: range.upperBound)) }
        }
        let sentence = rest.trimmingCharacters(in: .whitespaces)
        return sentence.isEmpty ? trimmed : sentence
    }
}
