import Foundation
@preconcurrency import Highlightr

/// Bridges the bundled Highlightr runtime to the syntax-highlighting engine.
final class HighlightrThemeAdapter {
    private let highlightr: Highlightr

    /// Creates an adapter when Highlightr can initialize its JavaScript engine.
    init?() {
        guard let highlightr = Highlightr() else { return nil }
        self.highlightr = highlightr
    }

    func setTheme(to name: String) -> Bool {
        highlightr.setTheme(to: name)
    }

    func highlight(_ text: String, as language: String?) -> NSAttributedString? {
        highlightr.highlight(text, as: language)
    }
}
