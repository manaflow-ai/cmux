import Foundation

/// Omnibox preloading between the omnibar and its page, the same for a
/// browser tab's toolbar (`BrowserChromeView`) and a popup window
/// (`OmnibarTabBinding`): only Chromium tabs preload (`BrowserOmniboxPreloading`).
extension AddressBarView {
    /// Preloads what this omnibar is about to load in `tab` (Chrome's omnibox
    /// preconnect and prerender), or nothing for a page that cannot.
    ///
    /// - Parameter tab: The page Enter loads in.
    public func bindPreloading(of tab: any BrowserTab) {
        controller.setPreloader(tab as? any BrowserOmniboxPreloading)
    }
}
