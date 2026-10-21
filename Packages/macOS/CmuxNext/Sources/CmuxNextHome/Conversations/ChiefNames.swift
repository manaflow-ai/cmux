public import Foundation

/// Names a person reads for the ids a Chief's engine reports (Leo 2026-10-21, #89: the Chief
/// settings showed `claude-sr2-pipe` and `claude-opus-5-5`). An official engine keeps its own
/// title (``ChiefBackend/title``) and a model the catalog names keeps that name; these are the
/// fallback for every other id, so a raw id never shows as a title. The raw id stays in a
/// tooltip or a detail line where one helps.
public nonisolated enum ChiefNames {
    /// A harness id as a name: the official engine it starts with, then the rest in brackets
    /// (`claude-sr2-pipe` → "Claude (SR2 Pipe)", `claude-cr` → "Claude (CodeRouter)",
    /// `gemini` → "Gemini"). A blank id comes back as it is.
    public static func harness(_ id: String) -> String {
        let parts = tokens(id)
        guard let first = parts.first else { return id }
        let lead = ChiefBackend(id: first.lowercased())?.title ?? word(first)
        let rest = parts.dropFirst().map { routes[$0.lowercased()] ?? word($0) }
        return rest.isEmpty ? lead : "\(lead) (\(rest.joined(separator: " ")))"
    }

    /// A model id as a name: words capitalized, a version's numbers joined by a dot, a trailing
    /// release date dropped, and a context suffix kept (`claude-opus-5-5` → "Claude Opus 5.5",
    /// `claude-sonnet-4-5-20250929` → "Claude Sonnet 4.5", `gpt-5.1-codex` → "GPT 5.1 Codex",
    /// `opus[1m]` → "Opus (1M)"). A blank id comes back as it is.
    public static func model(_ id: String) -> String {
        var base = id.trimmingCharacters(in: .whitespacesAndNewlines)
        var context: String?
        if base.hasSuffix("]"), let open = base.lastIndex(of: "[") {
            context = String(base[base.index(after: open)...].dropLast()).uppercased()
            base = String(base[..<open])
        }
        var parts = tokens(base)
        if let last = parts.last, last.count == 8, last.allSatisfy(\.isNumber) { parts.removeLast() }
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
                words.append(word(part))
            }
        }
        flush()
        let name = words.joined(separator: " ")
        guard let context, !context.isEmpty else { return name }
        return "\(name) (\(context))"
    }

    /// The route words acpmux's Claude harness ids use (`claude-cr`, `claude-sr`).
    private static let routes = ["cr": "CodeRouter", "sr": "Subrouter"]

    /// Words always written in capitals.
    private static let acronyms: Set<String> = ["gpt", "glm", "oss", "ai", "api", "acp", "llm", "xai"]

    /// The id's words: split on dashes, underscores, slashes, colons and spaces.
    private static func tokens(_ id: String) -> [Substring] {
        id.split { "-_/: ".contains($0) }
    }

    /// One word as a name: a known acronym or a short code (`cr`, `sr2`) in capitals, a version
    /// (`5.1`, `4o`) as it is, any other word with a capital first letter.
    private static func word(_ part: Substring) -> String {
        let lower = part.lowercased()
        if acronyms.contains(lower) { return lower.uppercased() }
        guard let first = part.first, first.isLetter else { return lower }
        let hasDigit = part.contains(where: \.isNumber)
        if part.count <= 2 || (hasDigit && part.count <= 4) { return lower.uppercased() }
        return lower.prefix(1).uppercased() + lower.dropFirst()
    }
}
