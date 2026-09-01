import Foundation

/// Classifies stable provider banners at a proven idle prompt.
///
/// The classifier is deliberately pure: it does not decide whether a pane is
/// managed, idle, or user-interrupted. The app supervisor supplies those
/// lifecycle facts before acting on this result. Provider rules are values so
/// adding a banner does not require changing the classification algorithm.
public struct AgentStallClassifier: Sendable {
    private let patterns: [AgentStallPattern]

    /// Creates a classifier with an ordered list of provider rules.
    ///
    /// The first matching rule wins. An empty rule, with no literal fragments
    /// or regular expressions, never matches.
    ///
    /// - Parameter patterns: Rules ordered from most specific to least specific.
    public init(patterns: [AgentStallPattern] = AgentStallClassifier.builtInPatterns) {
        self.patterns = patterns
    }

    /// Returns a classification only when the provider and banner match a rule.
    ///
    /// - Parameters:
    ///   - provider: Managed provider identifier or a supported alias.
    ///   - output: Bounded terminal output captured during one managed turn.
    ///   - hasStructuredEvidence: Whether the managed hook corroborated the output.
    /// - Returns: The first matching classification, or `nil` when evidence is insufficient.
    public func classify(
        provider: String,
        output: String,
        hasStructuredEvidence: Bool = false
    ) -> AgentStallClassification? {
        let canonicalProvider = Self.canonicalProvider(provider)
        guard !canonicalProvider.isEmpty else { return nil }
        let normalizedOutput = normalizedAgentStallOutput(output)
        guard !normalizedOutput.isEmpty else { return nil }
        // Terminal line wrapping can split a provider phrase at any column,
        // including in the middle of a word. Keep a whitespace-elided view
        // for literal evidence while the line-preserving view remains
        // available for anchored expressions.
        let fragmentOutput = normalizedOutput.filter { !$0.isWhitespace }
        guard let pattern = patterns.first(where: { pattern in
            pattern.providers.contains(canonicalProvider)
                && matches(
                    pattern,
                    output: normalizedOutput,
                    fragmentOutput: fragmentOutput,
                    hasStructuredEvidence: hasStructuredEvidence
                )
        }) else {
            return nil
        }
        return AgentStallClassification(provider: canonicalProvider, pattern: pattern)
    }

    private func matches(
        _ pattern: AgentStallPattern,
        output: String,
        fragmentOutput: String,
        hasStructuredEvidence: Bool
    ) -> Bool {
        guard !pattern.requiredFragments.isEmpty
                || !pattern.anyFragments.isEmpty
                || !pattern.regularExpressions.isEmpty else {
            return false
        }
        guard !pattern.requiresStructuredEvidence || hasStructuredEvidence else {
            return false
        }
        let requiredFragments = pattern.requiredFragments.map(normalizedAgentStallFragment)
        let anyFragments = pattern.anyFragments.map(normalizedAgentStallFragment)
        guard requiredFragments.allSatisfy({ !$0.isEmpty }),
              anyFragments.allSatisfy({ !$0.isEmpty }) else {
            return false
        }
        guard requiredFragments.allSatisfy({
            fragmentOutput.contains($0)
        }) else {
            return false
        }
        if !anyFragments.isEmpty,
           !anyFragments.contains(where: {
               fragmentOutput.contains($0)
           }) {
            return false
        }
        guard !pattern.regularExpressions.isEmpty else { return true }
        // A terminal can wrap one provider banner across physical lines. Keep
        // the line-preserving view for anchored rules, but also try a compact
        // whitespace view and a line-joined view so a split phrase remains
        // detectable whether the wrap occurred between words or mid-word.
        let whitespaceCollapsedOutput = output.replacingOccurrences(
            of: "\\s+",
            with: " ",
            options: .regularExpression
        )
        let lineJoinedOutput = output.replacingOccurrences(of: "\n", with: "")
        return pattern.regularExpressions.contains {
            output.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil
                || whitespaceCollapsedOutput.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil
                || lineJoinedOutput.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }

    /// Normalizes a managed provider identifier to its classifier ID.
    ///
    /// - Parameter provider: Provider identifier published by a hook or custom rule.
    /// - Returns: `claude`, `codex`, or the normalized custom provider identifier.
    public static let canonicalProvider: @Sendable (String) -> String = canonicalizeAgentStallProvider
}

private func normalizedAgentStallFragment(_ fragment: String) -> String {
    fragment
        .lowercased()
        .filter { !$0.isWhitespace }
}

private func canonicalizeAgentStallProvider(_ provider: String) -> String {
    let normalized = provider
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
        .replacingOccurrences(of: "_", with: "-")
    switch normalized {
    case "claude", "claude-code", "anthropic": return "claude"
    case "codex", "codex-cli", "openai", "openai-codex": return "codex"
    default: return normalized
    }
}

private func normalizedAgentStallOutput(_ output: String) -> String {
    var text = output
    text = text.replacingOccurrences(
        of: "\u{001B}\\][^\u{0007}\u{001B}]*(?:\u{0007}|\u{001B}\\\\)",
        with: " ",
        options: .regularExpression
    )
    text = text.replacingOccurrences(
        of: "\u{001B}\\[[0-?]*[ -/]*[@-~]",
        with: " ",
        options: .regularExpression
    )
    let normalizedLines = text
        .replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")
        .lowercased()
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map { $0.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") }
    return normalizedLines.joined(separator: "\n")
}
