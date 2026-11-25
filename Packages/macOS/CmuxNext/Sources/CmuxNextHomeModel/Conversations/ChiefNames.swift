public import Foundation

/// Names a person reads for the ids a Chief's engine reports (Leo 2026-10-21, #89: the Chief
/// settings showed `claude-sr2-pipe` and `claude-opus-5-5`). An official engine keeps its own
/// title (``ChiefBackend/title``) and a model the catalog names keeps that name; these are the
/// fallback for every other id, so a raw id never shows as a title. The raw id stays in a
/// tooltip or a detail line where one helps.
extension String {
    /// A harness id as a name: the official engine or acpmux built-in it starts with, then the
    /// rest in brackets (`claude-sr2-pipe` → "Claude (SR2 Pipe)", `claude-cr` → "Claude
    /// (CodeRouter)", `gemini` → "Gemini CLI"). A blank id comes back as it is.
    public nonisolated var chiefHarnessName: String {
        let id = self
        let parts = chiefNameTokens(id)
        guard let first = parts.first else { return id }
        let lead = ChiefBackend(id: first.lowercased())?.title ?? chiefNameBuiltins[first.lowercased()] ?? chiefNameWord(first)
        let rest = parts.dropFirst().map { chiefNameRoutes[$0.lowercased()] ?? chiefNameWord($0) }
        return rest.isEmpty ? lead : "\(lead) (\(rest.joined(separator: " ")))"
    }

    /// A model id as a name: words capitalized, a version's numbers joined by a dot, a trailing
    /// release date (`20250929` or `2024-08-06`, a real month and day) dropped, and a context suffix kept (`claude-opus-5-5` → "Claude Opus 5.5",
    /// `claude-sonnet-4-5-20250929` → "Claude Sonnet 4.5", `gpt-5.1-codex` → "GPT 5.1 Codex",
    /// `opus[1m]` → "Opus (1M)"). A blank id comes back as it is.
    public nonisolated var chiefModelName: String {
        let id = self
        var base = id.trimmingCharacters(in: .whitespacesAndNewlines)
        var context: String?
        if base.hasSuffix("]"), let open = base.lastIndex(of: "[") {
            context = String(base[base.index(after: open)...].dropLast()).uppercased()
            base = String(base[..<open])
        }
        var parts = chiefNameTokens(base)
        if let last = parts.last, last.count == 8, last.allSatisfy(\.isNumber),
           chiefNameIsDate([last.prefix(4), last.dropFirst(4).prefix(2), last.suffix(2)]) {
            parts.removeLast()
        } else if parts.count > 3, chiefNameIsDate(parts.suffix(3)) {
            parts.removeLast(3)
        }
        guard !parts.isEmpty else { return id }
        var words: [String] = []
        var version: [String] = []
        func flush() {
            if !version.isEmpty { words.append(version.joined(separator: ".")) }
            version = []
        }
        for part in parts {
            if part.count <= 2, part.allSatisfy(\.isNumber) {
                version.append(String(part))
            } else {
                flush()
                words.append(chiefNameWord(part))
            }
        }
        flush()
        let name = words.joined(separator: " ")
        guard let context, !context.isEmpty else { return name }
        return "\(name) (\(context))"
    }
}

/// The route words acpmux's Claude harness ids use (`claude-cr`, `claude-sr`).
private nonisolated let chiefNameRoutes = ["cr": "CodeRouter", "sr": "Subrouter"]

/// acpmux's built-in harnesses by acpmux's own names (`cmux-tui/crates/acpmux/harnesses/*.toml`).
private nonisolated let chiefNameBuiltins = [
    "aider": "Aider", "gemini": "Gemini CLI", "muse": "Muse Code", "opencode": "OpenCode", "pi": "Pi",
]

/// Whether `parts` (three tokens, or `YYYYMMDD` cut in three) are a `YYYY-MM-DD` date: a month of
/// 1 to 12 and a day of 1 to 31.
private nonisolated func chiefNameIsDate<Parts: Collection<Substring>>(_ parts: Parts) -> Bool {
    let numbers = zip(parts, [4, 2, 2]).compactMap { $0.count == $1 && $0.allSatisfy(\.isNumber) ? Int($0) : nil }
    guard numbers.count == 3 else { return false }
    return (1...12).contains(numbers[1]) && (1...31).contains(numbers[2])
}

/// Words always written in capitals.
private nonisolated let chiefNameAcronyms: Set<String> = ["gpt", "glm", "oss", "ai", "api", "acp", "llm", "xai"]

/// The id's words: split on dashes, underscores, slashes, colons and spaces.
private nonisolated func chiefNameTokens(_ id: String) -> [Substring] {
    id.split { "-_/: ".contains($0) }
}

/// One word as a name: a known acronym or a short code (`cr`, `sr2`) in capitals, a version
/// (`5.1`, `4o`) as it is, any other word with a capital first letter.
private nonisolated func chiefNameWord(_ part: Substring) -> String {
    let lower = part.lowercased()
    if chiefNameAcronyms.contains(lower) { return lower.uppercased() }
    guard let first = part.first, first.isLetter else { return lower }
    let hasDigit = part.contains(where: \.isNumber)
    if part.count <= 2 || (hasDigit && part.count <= 4) { return lower.uppercased() }
    return lower.prefix(1).uppercased() + lower.dropFirst()
}
