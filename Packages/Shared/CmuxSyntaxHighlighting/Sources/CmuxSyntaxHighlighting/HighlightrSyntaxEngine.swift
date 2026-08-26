import Foundation

/// v1 highlighting engine: highlight.js running in JavaScriptCore via Highlightr.
///
/// One `Highlightr` instance is reused, and its successfully applied active
/// theme is retained. Callers must still honor ``HighlightPolicy``; this actor
/// also applies the policy so a missed gate cannot push a multi-megabyte buffer
/// through JSC.
public actor HighlightrSyntaxEngine: SyntaxHighlightingEngine {
    private var themeApplying: (any HighlightrThemeApplying)?
    private var activeThemeName: String?
    private let policy: HighlightPolicy

    /// Creates an engine that applies `policy` before invoking Highlightr.
    public init(policy: HighlightPolicy = HighlightPolicy()) {
        self.policy = policy
    }

    /// Creates an engine with a supplied Highlightr adapter for package tests.
    init(
        policy: HighlightPolicy = HighlightPolicy(),
        themeApplying: any HighlightrThemeApplying
    ) {
        self.policy = policy
        self.themeApplying = themeApplying
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

        let highlightr: any HighlightrThemeApplying
        if let themeApplying {
            highlightr = themeApplying
        } else {
            guard let created = HighlightrThemeAdapter() else { return nil }
            themeApplying = created
            highlightr = created
        }

        let themeName = theme.highlightrThemeName
        if activeThemeName != themeName {
            guard highlightr.setTheme(to: themeName) else { return nil }
            activeThemeName = themeName
        }
        guard let highlighted = highlightr.highlight(text, as: language) else {
            return nil
        }
        let remapped = HighlightColorRemapper(theme: theme).remap(highlighted)
        return HighlightedText(remapped)
    }
}
