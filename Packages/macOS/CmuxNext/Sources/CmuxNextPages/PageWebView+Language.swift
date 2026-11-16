import CmuxNextSettings

// `app.language` reaches every first-party page: the page owns the language override and its
// fallbacks (webviews' `__cmuxSetAppLanguage`); this side only hands it the chosen code, nil for
// System. Pushed on every new document (``documentFinished()``, a claimed pooled page) and to
// every live page when the setting changes, so the cost is O(pages) per change and nothing per frame.
extension PageWebView {
    /// The chosen language code, nil for System (follow macOS). The app sets it from cmux.json
    /// (`AppLanguageApplier`); a change goes to every live page at once.
    public static var appLanguage: String? {
        get { appLanguageCode }
        set {
            guard newValue != appLanguageCode else { return }
            appLanguageCode = newValue
            for page in PageRegistry.pages() { page.applyLanguage() }
        }
    }

    @MainActor private static var appLanguageCode: String?

    /// The call that hands a page its language: the code as a JSON string, or `null` for System.
    /// Optional-called: a page bundle older than the global ignores it.
    nonisolated static func languageScript(_ code: String?) -> String {
        "window.__cmuxSetAppLanguage?.(\(code.map { JSONValue.string($0).compactText } ?? "null"));"
    }

    /// Pushes ``appLanguage`` to the loaded document (a page still loading gets it at its finish).
    public func applyLanguage() {
        guard loaded else { return }
        evaluateInPage(Self.languageScript(Self.appLanguage))
    }
}
