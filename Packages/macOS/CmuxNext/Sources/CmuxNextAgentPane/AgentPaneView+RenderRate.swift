import CmuxNextDesign
import CmuxNextPages
import WebKit

extension AgentPaneView {
    /// Whether the page renders at the display's full rate. It is fixed when the page is made
    /// (``renderRate``), as for every cmux page and browser tab: WebKit does not apply a live write
    /// of its near-60 preference to a page on screen (perf-lead row 23, cmux20, macOS 27, 120 Hz),
    /// and in Low Power Mode it halves every page by itself. A Chromium page always renders at the
    /// display's rate.
    public var rendersAtFullRate: Bool {
        if page?.showsChromium == true { return true }
        return webView.configuration.preferences.isWebKitFeatureEnabled(WebKitRenderRate.near60FPSFeature) == false
    }
}
