import Foundation
@preconcurrency import Highlightr

/// Bridges the bundled Highlightr runtime to the syntax-highlighting engine.
final class HighlightrThemeAdapter {
    private let highlightr: Highlightr

    /// Creates an adapter when Highlightr can initialize its JavaScript engine.
    init?() {
        guard let highlightr = Highlightr() else { return nil }
        // File Preview handles source files that embed another language (for
        // example dbt SQL with Jinja delimiters). Keep valid tokens around
        // grammar-illegal characters instead of aborting the whole document.
        highlightr.ignoreIllegals = true
        self.highlightr = highlightr
    }

    func setTheme(to name: String) -> Bool {
        highlightr.setTheme(to: name)
    }

    func highlight(_ text: String, as language: String?) -> NSAttributedString? {
        highlightr.highlight(text, as: language)
    }
}
