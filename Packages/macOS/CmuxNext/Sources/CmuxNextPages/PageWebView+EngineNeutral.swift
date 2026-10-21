public import AppKit
import Foundation
import WebKit

// Calls a host makes on a page whichever engine shows it. WebKit only so far: a Chromium page
// takes no picture and relays no extra handler yet.
extension PageWebView {
    /// Whether a Chromium page shows the document now.
    public var showsChromium: Bool { chromiumSession != nil }

    /// A picture of the page as it draws now (WebKit only).
    public func snapshot() async -> NSImage? {
        guard chromiumSession == nil else { return nil }
        return try? await webView.takeSnapshot(configuration: nil)
    }

    /// Adds a `window.webkit.messageHandlers.<name>` (not relayed from Chromium yet).
    public func addMessageHandler(_ name: String, handler: @escaping @MainActor (Any) -> Void) {}
}
