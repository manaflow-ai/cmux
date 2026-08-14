import Foundation
@preconcurrency import Highlightr

/// v1 highlighting engine: highlight.js running in JavaScriptCore via Highlightr.
///
/// One `Highlightr` instance is reused. Callers must still honor
/// ``HighlightPolicy``; this actor also applies the policy so a missed gate
/// cannot push a multi-megabyte buffer through JSC.
public actor HighlightrSyntaxEngine: SyntaxHighlightingEngine {
    private var engine: Highlightr?
    private let policy: HighlightPolicy

    /// Creates an engine that applies `policy` before invoking Highlightr.
    public init(policy: HighlightPolicy = HighlightPolicy()) {
        self.policy = policy
    }

    /// Highlights `text` as `language` using the Highlightr theme for `theme`.
    public func highlight(
        text: String,
        language: String?,
        theme: TokenTheme
    ) async -> HighlightedText? {
        guard policy.shouldHighlight(content: text, language: language) else {
            return nil
        }

        let highlightr: Highlightr
        if let engine {
            highlightr = engine
        } else {
            guard let created = Highlightr() else { return nil }
            engine = created
            highlightr = created
        }

        guard highlightr.setTheme(to: theme.highlightrThemeName),
              let highlighted = highlightr.highlight(text, as: language) else {
            return nil
        }
        return HighlightedText(highlighted)
    }
}
