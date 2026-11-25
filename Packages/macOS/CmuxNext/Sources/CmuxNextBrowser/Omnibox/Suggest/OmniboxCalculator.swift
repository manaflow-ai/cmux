public import Foundation

/// The calculator row (plans/cmux-next/omnibar-suggestions.md, "Sources"): `+ - * / % ^`, `×` and
/// `÷`, parentheses, unary minus and decimals. The arithmetic and the answer's text are
/// cmux-browser-rules' (`calculator`, with its tests): input that is not a whole expression with
/// at least one operator (a plain number, a word) has no row.
public nonisolated struct OmniboxCalculator {
    public init() {}

    /// The answer row for `text`, or nil when it is not arithmetic. Enter
    /// on it copies the answer; it never navigates or completes inline.
    public static func row(for text: String) -> BrowserSuggestion? {
        guard let answer = BrowserRules.call("browser_rules_calculator_answer", ["text": text], as: String?.self) ?? nil,
              let url = URL(string: "cmux-answer:" + (answer.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "0")) else {
            return nil
        }
        var row = BrowserSuggestion(kind: .answer, title: "= " + answer, detail: Strings.calculatorCopyHint, url: url, score: 999)
        row.content = answer
        row.inlineCompletable = false
        return row
    }
}
