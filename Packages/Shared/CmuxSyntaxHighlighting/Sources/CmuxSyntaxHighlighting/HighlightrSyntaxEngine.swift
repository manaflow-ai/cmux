import Foundation

/// v1 highlighting engine: highlight.js running in JavaScriptCore via Highlightr.
///
/// One `Highlightr` instance is reused, and its successfully applied active
/// theme is retained. Callers must still honor ``HighlightPolicy``; this actor
/// also applies the policy so a missed gate cannot push a multi-megabyte buffer
/// through JSC.
public actor HighlightrSyntaxEngine: SyntaxHighlightingEngine {
    private var highlightrAdapter: HighlightrThemeAdapter?
    private var activeThemeName: String?
    private let policy: HighlightPolicy
    private var latestRequestID = 0

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
        guard !Task.isCancelled else { return nil }
        latestRequestID &+= 1
        let requestID = latestRequestID
        // Yield before touching the policy or JavaScriptCore. Actor reentrancy
        // lets a newer edit publish its request ID here, dropping stale queued
        // requests instead of tokenizing every intermediate document.
        await Task.yield()
        guard !Task.isCancelled, requestID == latestRequestID else { return nil }
        guard policy.shouldHighlight(content: text, language: language) else {
            return nil
        }

        // Initializing Highlightr creates its JavaScriptCore context. Do not
        // start that work if this request was canceled while the policy scan
        // was running or superseded while the actor was re-entrant.
        guard !Task.isCancelled, requestID == latestRequestID else { return nil }
        let highlightr: HighlightrThemeAdapter
        if let highlightrAdapter {
            highlightr = highlightrAdapter
        } else {
            guard let created = HighlightrThemeAdapter() else { return nil }
            highlightrAdapter = created
            highlightr = created
        }

        guard !Task.isCancelled, requestID == latestRequestID else { return nil }
        let themeName = theme.highlightrThemeName
        if activeThemeName != themeName {
            guard !Task.isCancelled, requestID == latestRequestID else { return nil }
            guard highlightr.setTheme(to: themeName) else { return nil }
            activeThemeName = themeName
        }
        guard !Task.isCancelled, requestID == latestRequestID else { return nil }
        guard let highlighted = highlightr.highlight(text, as: language) else {
            return nil
        }
        guard !Task.isCancelled, requestID == latestRequestID else { return nil }
        let remapped = HighlightColorRemapper(theme: theme).remap(highlighted)
        return HighlightedText(remapped)
    }
}
