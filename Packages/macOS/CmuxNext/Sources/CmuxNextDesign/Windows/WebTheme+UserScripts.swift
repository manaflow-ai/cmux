public import WebKit

extension WebTheme {
    /// The document-start scripts every cmux web view installs: ``bootstrapScript``
    /// (`window.cmuxTheme`). Main frame only, in the page's world. The UI font needs none: `--font-ui`
    /// is the system font, which every page already has.
    @MainActor public static var userScripts: [WKUserScript] {
        [WKUserScript(source: bootstrapScript, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page)]
    }

    /// Adds ``userScripts`` to `controller`.
    @MainActor public static func installUserScripts(on controller: WKUserContentController) {
        userScripts.forEach(controller.addUserScript)
    }
}
