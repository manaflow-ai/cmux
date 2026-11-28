import CmuxNextDesign
import WebKit

extension PageWebView {
    /// Applies this view's theme at document start, right after ``WebTheme/bootstrapScript``, so
    /// the page's first frame already has its colors (no-flicker F1). `applyTheme` reaches a
    /// document only once it finished loading; until then a page painted with no theme, and a
    /// page without its own background painted white. `didFinish` still applies the scope's
    /// current theme, so one that changed since this script was installed wins.
    func installDocumentStartTheme() {
        webView.configuration.userContentController.addUserScript(
            WKUserScript(source: currentTheme().applyScript, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
    }
}
