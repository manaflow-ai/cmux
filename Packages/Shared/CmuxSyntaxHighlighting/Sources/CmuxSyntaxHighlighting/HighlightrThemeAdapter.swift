import Foundation
@preconcurrency import Highlightr

/// Bridges the Highlightr dependency to the package's testable internal seam.
final class HighlightrThemeAdapter: HighlightrThemeApplying {
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
