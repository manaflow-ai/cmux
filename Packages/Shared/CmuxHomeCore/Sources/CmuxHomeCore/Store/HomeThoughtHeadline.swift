import Foundation

/// The headline of one of the Chief's thoughts: what its running indicator shows as progress narration.
///
/// The live book publishes this, not the whole thought, so a streamed thought token changes the
/// store's live state only when the line a person sees changes.
public enum HomeThoughtHeadline {
    /// Most characters a headline keeps.
    public static let limit = 72

    /// A thought's headline: its last bold heading line ("**Checking the tests**", how Claude and
    /// Codex title their reasoning summaries), else its last sentence, as plain text of at most
    /// ``limit`` characters. Nil for a thought with no words.
    public static func of(_ thought: String) -> String? {
        let lines = thought.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let heading = lines.last { $0.count > 4 && $0.hasPrefix("**") && $0.hasSuffix("**") }
        let raw: String
        if let heading {
            raw = String(heading.dropFirst(2).dropLast(2))
        } else if let last = lines.last {
            raw = lastSentence(last)
        } else {
            return nil
        }
        let plain = raw.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "*_#> ").union(.whitespaces))
        guard !plain.isEmpty else { return nil }
        guard plain.count > limit else { return plain }
        return String(plain.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// The last sentence of `line` (after its last ". ", "! " or "? "), or the line.
    static func lastSentence(_ line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
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
