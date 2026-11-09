import Foundation

/// What a failed app mount says, in plain words (Lawrence 2026-11-07: "we need better error messages
/// in the chat ui itself", on `init: main: Error: expecting ';' at eval_script:2:12`).
///
/// The supervisor's reason is the app host's own text: the phase it failed in (`init:`, `main:`), the
/// engine's error name and message, and the place: `main.js:LINE:COLUMN` (an older host says
/// `eval_script:LINE:COLUMN`). A row says what happened
/// (``title``) and, for a script error, where and why (``location``); the raw reason stays whole in
/// ``detail`` for Details and Copy Error.
struct AppFailureCopy: Equatable, Sendable {
    /// The row's first line.
    let title: String
    /// `main.js · Line 2, column 12: expecting ';'` for a script error that names its place; nil otherwise.
    let location: String?
    /// The reason exactly as the supervisor sent it.
    let detail: String

    /// - Parameter reason: The mount's failure reason (``AppSceneModel/Status/failed(_:)``).
    init(reason: String) {
        detail = reason
        let text = Self.strippingPhases(reason)
        let named = text.firstMatch(of: /^(?:[A-Z][A-Za-z]*)?(?:Error|Exception):\s*/)
        let at = text.firstMatch(of: /\s*\(?\s*\bat\s+(?:(?:<[^>]*>|[\w$.]+)\s+)?\(?([\w.\/-]+\.(?:js|mjs|cjs)|eval_script):(\d+):(\d+)\)?/)
        if text.hasPrefix("app.limit:") {
            title = AppsStrings.failureTooLarge
            location = nil
        } else if let at {
            title = AppsStrings.failureScript
            // `named` and `at` both take the spaces between them, so an empty message ("Error: at
            // eval_script:1:1") can put the name's end past the place's start: clamp, never a reversed range.
            let start = min(named?.range.upperBound ?? text.startIndex, at.range.lowerBound)
            let message = text[start..<at.range.lowerBound].trimmingCharacters(in: .whitespaces)
            let file = at.output.1 == "eval_script" ? nil : String(at.output.1)
            location = AppsStrings.failureScriptAt(file: file, line: String(at.output.2), column: String(at.output.3), message: message)
        } else if let named {
            // A JS error with no place (`ReferenceError: x is not defined`): its message is the line.
            title = AppsStrings.failureScript
            location = String(text[named.range.upperBound...]).trimmingCharacters(in: .whitespaces)
        } else {
            title = AppsStrings.failureGeneric
            location = nil
        }
    }

    /// The reason without the host's phase prefixes (`init: main: `).
    private static func strippingPhases(_ reason: String) -> String {
        var text = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        while let match = text.firstMatch(of: /^(?:init|main|runtime|mount|render):\s*/) {
            text.removeSubrange(match.range)
        }
        return text
    }
}
