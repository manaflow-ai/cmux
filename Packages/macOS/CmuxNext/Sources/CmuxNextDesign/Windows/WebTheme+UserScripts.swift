public import WebKit

extension WebTheme {
    /// The document-start scripts every cmux web view installs, in order: ``bootstrapScript``
    /// (`window.cmuxTheme`), then the UI font's face (`BundledFonts.pageScript`: Inter, which
    /// `--font-ui` names first). Main frame only, in the page's world.
    @MainActor public static var userScripts: [WKUserScript] {
        [bootstrapScript, BundledFonts.pageScript].map {
            WKUserScript(source: $0, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page)
        }
    }

    /// Adds ``userScripts`` to `controller`.
    @MainActor public static func installUserScripts(on controller: WKUserContentController) {
        userScripts.forEach(controller.addUserScript)
    }
}
