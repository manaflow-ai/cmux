/// Aggregated view of the font-related directives found while scanning a user's
/// Ghostty config files, used by ``GhosttyConfigDiscovery`` to decide whether to
/// auto-inject a CJK `font-codepoint-map` fallback.
public struct UserFontConfigSummary: Equatable, Sendable {
    /// Whether any non-empty `font-codepoint-map` directive was seen.
    public var containsCodepointMap = false
    /// The ordered, de-duplicated list of effective `font-family` values; an
    /// empty `font-family` clears the accumulated list (Ghostty reset
    /// semantics).
    public var effectiveFontFamilies: [String] = []

    /// Creates an empty summary.
    public init() {}

    /// Whether the user provided an explicit multi-entry `font-family` fallback
    /// chain (more than one effective family), which suppresses cmux's injected
    /// CJK fallback.
    public var hasExplicitFontFamilyFallbackChain: Bool {
        effectiveFontFamilies.count > 1
    }

    /// Records a `font-codepoint-map` directive value, clearing the flag on an
    /// empty value and otherwise setting it only when the value contains a
    /// range/font separator.
    public mutating func applyFontCodepointMap(_ value: String) {
        if value.isEmpty {
            containsCodepointMap = false
            return
        }

        guard value.contains("=") else {
            return
        }

        containsCodepointMap = true
    }

    /// Records a `font-family` directive value, resetting the accumulated list
    /// on an empty value and otherwise appending the value when not already
    /// present.
    public mutating func recordFontFamily(_ value: String) {
        if value.isEmpty {
            effectiveFontFamilies.removeAll()
            return
        }

        guard !effectiveFontFamilies.contains(value) else {
            return
        }

        effectiveFontFamilies.append(value)
    }
}
