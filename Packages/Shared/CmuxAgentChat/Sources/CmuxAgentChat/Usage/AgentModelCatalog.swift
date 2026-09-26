import Foundation

/// Resolves model ids found in agent transcripts to a display name, context
/// window, and published list prices.
///
/// The price table is deliberately small and explicit: a model that is not
/// listed gets no cost estimate instead of a guessed one. Only Anthropic
/// models are priced; Codex/OpenAI models show model and context only.
///
/// ```swift
/// let info = AgentModelCatalog().info(forModelID: "claude-opus-4-8")
/// // info?.displayName == "Opus 4.8", info?.contextWindow == 1_000_000
/// ```
public struct AgentModelCatalog: Sendable {
    /// Context window assumed for Claude models not known to support 1M.
    public static let defaultClaudeContextWindow = 200_000
    /// Context window for 1M-token models (and `[1m]` model ids).
    public static let oneMillionContextWindow = 1_000_000

    /// Claude model families (id without the `claude-` prefix and any date
    /// suffix) that run with a 1M-token context window by default.
    static let claudeOneMillionFamilies: Set<String> = [
        "fable-5-1", "fable-5", "mythos-5-1", "mythos-5",
        "opus-5-5", "opus-5", "opus-4-8", "opus-4-7", "opus-4-6",
        "sonnet-5", "sonnet-4-6",
    ]

    /// Anthropic first-party API list prices in USD per million tokens,
    /// keyed by normalized family. Source: Anthropic model/pricing tables as
    /// of 2026-06-24 (input, output, cache read; 5-minute and 1-hour cache
    /// writes are 1.25x and 2x input). Update this table and its date
    /// together.
    static let claudePrices: [String: AgentModelPricing] = [
        "fable-5-1": .anthropic(input: 10, output: 50, cacheRead: 0.25),
        "mythos-5-1": .anthropic(input: 10, output: 50, cacheRead: 0.25),
        "fable-5": .anthropic(input: 10, output: 50, cacheRead: 1),
        "mythos-5": .anthropic(input: 10, output: 50, cacheRead: 1),
        "opus-5-5": .anthropic(input: 4, output: 20, cacheRead: 0.2),
        "opus-5": .anthropic(input: 5, output: 25, cacheRead: 0.5),
        "opus-4-8": .anthropic(input: 5, output: 25, cacheRead: 0.5),
        "opus-4-7": .anthropic(input: 5, output: 25, cacheRead: 0.5),
        "opus-4-6": .anthropic(input: 5, output: 25, cacheRead: 0.5),
        "opus-4-5": .anthropic(input: 5, output: 25, cacheRead: 0.5),
        "opus-4-1": .anthropic(input: 15, output: 75, cacheRead: 1.5),
        "opus-4": .anthropic(input: 15, output: 75, cacheRead: 1.5),
        "sonnet-5": .anthropic(input: 2, output: 10, cacheRead: 0.2),
        "sonnet-4-6": .anthropic(input: 3, output: 15, cacheRead: 0.3),
        "sonnet-4-5": .anthropic(input: 3, output: 15, cacheRead: 0.3),
        "sonnet-4": .anthropic(input: 3, output: 15, cacheRead: 0.3),
        "haiku-4-5": .anthropic(input: 1, output: 5, cacheRead: 0.1),
    ]

    /// Creates a catalog over the built-in tables.
    public init() {}

    /// Describes a model id as written in a transcript.
    ///
    /// Claude ids may carry a provider prefix (`us.anthropic.`), a date
    /// suffix (`-20251001`), a Vertex version (`@20251001`), a Bedrock
    /// version (`-v1:0`), or a `[1m]` suffix; all are normalized before
    /// lookup. `[1m]` forces a 1M context window.
    ///
    /// - Parameters:
    ///   - modelID: The raw model id.
    ///   - reportedContextWindow: A context window the transcript itself
    ///     reported (Codex `model_context_window`); wins over the table.
    /// - Returns: The model description, or `nil` for an empty id.
    public func info(forModelID modelID: String, reportedContextWindow: Int? = nil) -> AgentModelInfo? {
        let trimmed = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lowered = trimmed.lowercased()
        if let family = Self.claudeFamily(fromModelID: lowered) {
            let forcesOneMillion = lowered.contains("[1m]")
            let tableWindow = forcesOneMillion || Self.claudeOneMillionFamilies.contains(family)
                ? Self.oneMillionContextWindow
                : Self.defaultClaudeContextWindow
            return AgentModelInfo(
                displayName: Self.claudeDisplayName(family: family) ?? trimmed,
                contextWindow: reportedContextWindow ?? tableWindow,
                pricing: Self.claudePrices[family]
            )
        }
        return AgentModelInfo(displayName: trimmed, contextWindow: reportedContextWindow, pricing: nil)
    }

    /// Extracts the normalized Claude family (`opus-4-8`) from an id such as
    /// `us.anthropic.claude-opus-4-8-20260101-v1:0[1m]` or
    /// `claude-haiku-4-5@20251001`, or `nil` when the id is not a Claude id.
    static func claudeFamily(fromModelID lowered: String) -> String? {
        guard let range = lowered.range(of: "claude-") else { return nil }
        var rest = String(lowered[range.upperBound...])
        if let cut = rest.firstIndex(where: { $0 == "[" || $0 == "@" || $0 == ":" }) {
            rest = String(rest[..<cut])
        }
        var parts: [String] = []
        for part in rest.split(separator: "-") {
            // A date stamp (8 digits) or provider version suffix ends the family.
            if part.count == 8, part.allSatisfy(\.isNumber) { break }
            if part.hasPrefix("v"), part.dropFirst().first?.isNumber == true { break }
            parts.append(String(part))
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: "-")
    }

    /// `opus-4-8` → `Opus 4.8`. Returns `nil` for legacy ids such as
    /// `3-5-sonnet` whose first component is not a family name.
    static func claudeDisplayName(family: String) -> String? {
        let parts = family.split(separator: "-")
        guard let name = parts.first, name.first?.isLetter == true else { return nil }
        let version = parts.dropFirst().prefix { $0.allSatisfy(\.isNumber) }
        let title = name.prefix(1).uppercased() + name.dropFirst()
        guard !version.isEmpty else { return title }
        return title + " " + version.joined(separator: ".")
    }
}
