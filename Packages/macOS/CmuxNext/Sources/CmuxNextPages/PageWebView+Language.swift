import CmuxNextDesign
import CmuxNextSettings

// `app.language` reaches every first-party page: the page owns the language override and its
// fallbacks (webviews' `__cmuxSetAppLanguage`); this side only hands it the chosen code
// (`DesignSettings.appLanguage`, nil for System). Pushed on every new document
// (``documentFinished()``, a claimed pooled page) and, by ``AppLanguageApplier``, to every live
// page when the setting changes: O(pages) per change, nothing per frame.
extension PageWebView {
    /// The call that hands a page its language: the code as a JSON string, or `null` for System.
    /// Optional-called: a page bundle older than the global ignores it.
    nonisolated static func languageScript(_ code: String?) -> String {
        "window.__cmuxSetAppLanguage?.(\(code.map { JSONValue.string($0).compactText } ?? "null"));"
    }

    /// Pushes the app's language to the loaded document (a page still loading gets it at its finish).
    public func applyLanguage() {
        guard loaded else { return }
        evaluateInPage(Self.languageScript(DesignSettings.shared.appLanguage))
    }
}
