public import AppKit
import Foundation
import WebKit

// Calls a host makes on a page whichever engine shows it (WebKit, or Chromium through the DevTools
// protocol), so a host never reaches into ``PageWebView/webKitView`` for them: a script, a picture
// of the page, the next drawn frame, and extra message handlers. A function's value is
// ``PageWebView/callPageFunction(_:arguments:)``.
extension PageWebView {
    /// Whether a Chromium page shows the document now (``engineDecision`` may still say Chromium
    /// while the page starts).
    public var showsChromium: Bool { chromiumSession != nil }

    /// Runs `script` in the page's main frame, in whichever engine shows it, after the scripts sent
    /// before it. No result.
    public func evaluate(_ script: String) {
        evaluateInPage(script)
    }

    /// A picture of the page as it draws now, at the view's size in points; nil when there is none.
    ///
    /// In Chromium it is a fast-mode JPEG: the browser encodes the capture on its UI thread, which
    /// is the app's main thread, and a full retina PNG took 80-140 ms there (see `CEFThumbnail`).
    /// The picture is a cover shown while the page draws again, so JPEG is plenty. The reply (a
    /// multi-megabyte base64 string) is parsed and decoded off the main actor.
    public func snapshot() async -> NSImage? {
        guard let page = chromiumSession?.page else { return try? await webView.takeSnapshot(configuration: nil) }
        guard let json = try? await page.devTools("Page.captureScreenshot", params: Self.snapshotParams),
              let data = await Self.screenshotData(json), let image = NSImage(data: data) else { return nil }
        image.size = bounds.size
        return image
    }

    /// Whether ``snapshot()`` keeps the page's clear areas the color the pane shows under them. A
    /// Chromium picture is a JPEG, with no alpha: a clear page comes out black, so it is no cover for a
    /// page that has not drawn yet (Cmd-T spam drew a black New Tab page, 2026-10-24).
    public var snapshotKeepsClearAreas: Bool { chromiumSession == nil }

    /// `Page.captureScreenshot` for ``snapshot()``.
    nonisolated static var snapshotParams: [String: any Sendable] { ["format": "jpeg", "quality": 85, "optimizeForSpeed": true] }

    /// The image bytes of a `Page.captureScreenshot` reply, parsed off the main actor.
    @concurrent nonisolated static func screenshotData(_ json: String) async -> Data? {
        guard let object = ChromiumPageHostWire.object(json), let base64 = object["data"] as? String else { return nil }
        return Data(base64Encoded: base64)
    }

    /// Runs `body` once the page drew its next frame: an animation frame and a task in the page, then
    /// (WebKit) the next presentation update the window shows. Now when the page is gone.
    public func afterNextFrame(_ body: @escaping () -> Void) {
        let wait = "await new Promise((done) => requestAnimationFrame(() => setTimeout(done, 0)));"
        // task-owner: one frame wait; ends with the page's answer (or at once when the page is gone)
        Task { @MainActor [weak self] in
            guard let self else { return body() }
            _ = await self.callPageFunction(wait)
            guard self.chromiumSession == nil else { return body() }
            Self.afterPresentationUpdate(of: self.webView, body)
        }
    }

    /// WebKit's next presentation update (the layer tree the window shows), then `body`.
    private static func afterPresentationUpdate(of webView: WKWebView, _ body: @escaping () -> Void) {
        // crash-allow: WebKit private selector, used only after responds(to:) confirms it exists (no unknown-selector exception).
        let selector = NSSelectorFromString("_doAfterNextPresentationUpdate:")
        guard webView.responds(to: selector) else { return body() }
        typealias Action = @convention(block) () -> Void
        // WebKit keeps the block until the update: it must be an escaping one.
        let action: Action = { body() }
        webView.perform(selector, with: action)
    }

    /// Adds a `window.webkit.messageHandlers.<name>` the page posts to without a reply, in either
    /// engine; `handler` gets each main-frame message's body. Add it before the page starts (the view
    /// was just made): a Chromium page installs its handlers once, when it attaches.
    ///
    /// - Parameters:
    ///   - name: The handler name.
    ///   - handler: Gets each message's body.
    public func addMessageHandler(_ name: String, handler: @escaping @MainActor (Any) -> Void) {
        chromiumMessageHandlers[name] = handler
        let controller = webView.configuration.userContentController
        controller.removeScriptMessageHandler(forName: name, contentWorld: .page)
        controller.add(PageMessageRelay(view: self, handler: handler), contentWorld: .page, name: name)
    }

    /// Removes a handler ``addMessageHandler(_:handler:)`` added.
    public func removeMessageHandler(_ name: String) {
        chromiumMessageHandlers[name] = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: name, contentWorld: .page)
    }
}

/// One extra WebKit message handler of a ``PageWebView``: main-frame messages of its own view only.
private final class PageMessageRelay: NSObject, WKScriptMessageHandler {
    private weak var view: PageWebView?
    private let handler: @MainActor (Any) -> Void

    init(view: PageWebView, handler: @escaping @MainActor (Any) -> Void) {
        self.view = view
        self.handler = handler
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let view, message.webView === view.webKitView, message.frameInfo.isMainFrame else { return }
        handler(message.body)
    }
}
