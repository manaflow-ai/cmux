import Foundation
@preconcurrency import Highlightr

/// Serializes JavaScriptCore-backed syntax highlighting away from AppKit's main actor.
actor FilePreviewSyntaxHighlighter {
    private var engine: Highlightr?
    private let policy = FilePreviewSyntaxHighlightPolicy()

    func highlight(
        text: String,
        path: String,
        theme: FilePreviewHighlightTheme
    ) -> FilePreviewHighlightedText? {
        guard !Task.isCancelled else { return nil }
        let decision = policy.decision(path: path, byteCount: text.utf8.count)
        guard case .highlight(let language) = decision else { return nil }

        let highlightr: Highlightr
        if let engine {
            highlightr = engine
        } else {
            guard let newEngine = Highlightr() else { return nil }
            engine = newEngine
            highlightr = newEngine
        }

        let themeName = theme == .dark ? "xcode-dark" : "xcode"
        guard !Task.isCancelled,
              highlightr.setTheme(to: themeName),
              let highlighted = highlightr.highlight(text, as: language) else {
            return nil
        }
        return FilePreviewHighlightedText(highlighted)
    }
}
