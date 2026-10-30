public import WebKit

extension NSObject {
    /// The private WebKit selector `name` when this object implements it, else nil (a WebKit without that SPI).
    /// This module's one lookup of a selector by its name: a caller gets the selector only from
    /// `responds(to:)`, so it never sends an unknown selector (an Objective-C exception).
    package func webKitSPI(_ name: String) -> Selector? {
        // crash-allow: WebKit private selector, returned only after responds(to:) confirms this object implements it (no unknown-selector exception).
        let selector = NSSelectorFromString(name)
        return responds(to: selector) ? selector : nil
    }
}

extension WKWebView {
    /// The WebContent process this view's page runs in (`_webProcessIdentifier`, WebKit SPI, as CmuxNextResources
    /// `WebContentProcess` reads it); nil before the first load, after the process ended, or without the SPI.
    package var contentProcessID: Int32? {
        guard webKitSPI("_webProcessIdentifier") != nil,
              // crash-allow: KVC read of the WebKit private key above, only after webKitSPI confirmed this view implements it.
              let pid = (value(forKey: "_webProcessIdentifier") as? NSNumber)?.int32Value, pid > 0 else { return nil }
        return pid
    }
}
