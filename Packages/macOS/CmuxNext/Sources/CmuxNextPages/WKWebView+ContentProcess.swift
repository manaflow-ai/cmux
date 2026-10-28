public import WebKit

extension WKWebView {
    /// The WebContent process this view's page runs in (`_webProcessIdentifier`, WebKit SPI, as CmuxNextResources
    /// `WebContentProcess` reads it); nil before the first load, after the process ended, or without the SPI.
    package var contentProcessID: Int32? {
        // crash-allow: WebKit private selector, used only after responds(to:) confirms it exists (no unknown-selector exception).
        let selector = NSSelectorFromString("_webProcessIdentifier")
        guard responds(to: selector),
              // crash-allow: KVC read of the WebKit private key above, only after responds(to:) confirmed it.
              let pid = (value(forKey: "_webProcessIdentifier") as? NSNumber)?.int32Value, pid > 0 else { return nil }
        return pid
    }
}
