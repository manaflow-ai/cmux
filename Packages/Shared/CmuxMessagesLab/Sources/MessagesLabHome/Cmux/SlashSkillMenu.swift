// cmux: the state of the Chief composer's `/` menu: the command being typed, the skills that
// match it and the selected row. Not a vendored file.
import Foundation

/// The `/` menu of a draft: open while the field starts with `/` and the caret is in the command.
///
/// Matching is case-insensitive: names that start with the query first, then names with a word
/// (after `-`, `_`, `:` or `.`) that starts with it, then names that hold it, then descriptions
/// that hold it; each group keeps the catalog's order.
struct SlashSkillMenu: Equatable {
    /// The words typed after the slash.
    let query: String
    /// The UTF-16 length of the command, slash included (what a pick replaces).
    let commandLength: Int
    /// The matching skills, best first.
    let matches: [SlashSkill]
    /// The selected row of `matches`.
    private(set) var selected = 0
    /// The list has not loaded yet: the empty menu says it is loading, not that nothing matches.
    var isLoading = false
    /// The list could not load (a paired server's host did not answer): the empty menu says so.
    var loadFailed = false

    /// The menu of `text` with the caret at UTF-16 offset `caret`, nil when the field holds no
    /// command there (no leading slash, a path, or the caret past the command).
    init?(text: String, caret: Int, skills: [SlashSkill]) {
        let ns = text as NSString
        guard ns.length > 0, ns.character(at: 0) == 0x2F else { return nil }
        let space = ns.rangeOfCharacter(from: .whitespacesAndNewlines)
        let end = space.location == NSNotFound ? ns.length : space.location
        guard caret >= 1, caret <= end else { return nil }
        let query = ns.substring(with: NSRange(location: 1, length: end - 1))
        guard !query.contains("/") else { return nil }
        self.query = query
        commandLength = end
        matches = Self.rank(skills, query: query)
    }

    /// The selected skill; nil when nothing matches.
    var choice: SlashSkill? { matches.dropFirst(selected).first }

    /// Whether the command already names the selected skill exactly (Return then sends).
    var isComplete: Bool { choice.map { $0.name.caseInsensitiveCompare(query) == .orderedSame } ?? false }

    /// Moves the selection by `delta` rows, wrapping at both ends.
    mutating func move(_ delta: Int) {
        guard !matches.isEmpty else { return }
        selected = ((selected + delta) % matches.count + matches.count) % matches.count
    }

    /// Selects row `index` when it exists.
    mutating func select(_ index: Int) {
        if matches.indices.contains(index) { selected = index }
    }

    /// `text` with the command replaced by the selected skill's, a space after it, and the
    /// caret's UTF-16 offset after that space; nil when nothing matches.
    func applied(to text: String) -> (text: String, caret: Int)? {
        guard let choice else { return nil }
        let ns = text as NSString
        let rest = ns.substring(from: commandLength)
        let command = "/" + choice.name
        let joined = rest.first?.isWhitespace == true ? command + rest : command + " " + rest
        return (joined, (command as NSString).length + 1)
    }

    private static func rank(_ skills: [SlashSkill], query: String) -> [SlashSkill] {
        let q = query.lowercased()
        guard !q.isEmpty else { return skills }
        var prefix: [SlashSkill] = [], word: [SlashSkill] = [], inName: [SlashSkill] = [], inSummary: [SlashSkill] = []
        for skill in skills {
            let name = skill.name.lowercased()
            if name.hasPrefix(q) {
                prefix.append(skill)
            } else if name.split(whereSeparator: { "-_:.".contains($0) }).contains(where: { $0.hasPrefix(q) }) {
                word.append(skill)
            } else if name.contains(q) {
                inName.append(skill)
            } else if skill.summary.lowercased().contains(q) {
                inSummary.append(skill)
            }
        }
        return prefix + word + inName + inSummary
    }
}
