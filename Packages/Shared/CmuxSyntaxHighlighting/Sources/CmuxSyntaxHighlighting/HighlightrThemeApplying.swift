import Foundation

/// Internal seam for applying a Highlightr theme and producing attributed text.
protocol HighlightrThemeApplying: AnyObject {
    func setTheme(to name: String) -> Bool
    func highlight(_ text: String, as language: String?) -> NSAttributedString?
}
