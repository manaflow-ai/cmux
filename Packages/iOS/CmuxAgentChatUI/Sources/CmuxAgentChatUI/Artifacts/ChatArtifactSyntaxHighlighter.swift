import Foundation
@preconcurrency import Highlightr

/// Serializes JavaScriptCore-backed highlighting away from the main actor.
actor ChatArtifactSyntaxHighlighter {
    private var engine: Highlightr?

    /// Highlights a complete artifact using the palette for the current appearance.
    func highlight(
        text: String,
        language: String?,
        theme: ChatArtifactHighlightTheme
    ) -> ChatArtifactHighlightedText? {
        let highlightr: Highlightr
        if let engine {
            highlightr = engine
        } else {
            guard let newEngine = Highlightr() else { return nil }
            engine = newEngine
            highlightr = newEngine
        }

        let themeName = theme == .dark ? "xcode-dark" : "xcode"
        guard highlightr.setTheme(to: themeName),
              let highlighted = highlightr.highlight(text, as: language) else {
            return nil
        }
        return ChatArtifactHighlightedText(highlighted)
    }
}
