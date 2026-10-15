public import WebKit

/// The WebContent process of a web view (`_webProcessIdentifier`, WebKit SPI): what a
/// WebKit page's or agent chat's memory is measured on (`ProcessUsage.physFootprint`).
public struct WebContentProcess {
    public init() {}

    /// The process id; nil before the first load or after the process ended.
    @MainActor
    public static func identifier(of webView: WKWebView) -> Int32? {
        // crash-allow: WebKit private selector, used only after responds(to:) confirms it exists (no unknown-selector exception).
        let selector = NSSelectorFromString("_webProcessIdentifier")
        guard webView.responds(to: selector),
              // crash-allow: KVC read of the WebKit private key above, only after responds(to:) confirmed it.
              let pid = (webView.value(forKey: "_webProcessIdentifier") as? NSNumber)?.int32Value, pid > 0 else { return nil }
        return pid
    }
}
