public import AppKit
import CmuxNextBrowserCore
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

    /// Runs the fixed `body` with `text` as its string parameter `name`, in whichever engine shows
    /// the page, after the scripts sent before it. No result. For a push at a steady rate: WebKit
    /// keeps every distinct script text it ran, so a push of new data never builds a new script (RFD 0062).
    public func evaluate(_ body: String, argument name: String, text: String) {
        scriptTarget.bridge.evaluate(body, argument: name, text: text)
    }

    /// A picture of the page as it draws now, at the view's size in points; nil when there is none.
    ///
    /// In Chromium it is a fast-mode JPEG: the browser encodes the capture on its UI thread, which
    /// is the app's main thread, and a full retina PNG took 80-140 ms there (see `CEFThumbnail`).
    /// The picture is a cover shown while the page draws again, so JPEG is plenty. The reply (a
    /// multi-megabyte base64 string) is parsed and decoded off the main actor.
    public func snapshot() async -> NSImage? {
        guard let page = chromiumSession?.page else { return try? await webView.takeSnapshot(configuration: nil) }
        // Out of sight, the page draws for its picture (a parked spare's cover).
        let heldAway = holdAwayDrawing()
        defer { if heldAway { releaseAwayDrawing() } }
        guard let json = try? await page.devTools("Page.captureScreenshot", params: Self.snapshotParams),
              let data = await Self.screenshotData(json), let image = NSImage(data: data) else { return nil }
        image.size = bounds.size
        return image
    }

    /// A picture of the page as it draws now with its clear areas kept clear, at the view's size in points; nil when
    /// there is none. In Chromium it is a fast-mode PNG of the whole viewport (no clip: a clip with a scale lays the page
    /// out again), which costs the main thread more than ``snapshot()``'s JPEG: it is for a cover of a page the pane shows
    /// through (a New Tab page), taken at a quiet moment (a parked New Tab spare), once per size and content.
    public func clearAreaSnapshot() async -> NSImage? {
        guard let page = chromiumSession?.page else { return try? await webView.takeSnapshot(configuration: nil) }
        guard let json = try? await page.devTools("Page.captureScreenshot", params: Self.clearAreaSnapshotParams),
              let data = await Self.screenshotData(json), let image = NSImage(data: data) else { return nil }
        // The viewport: the page window lays its web contents one point under its top edge (``chromiumFrameBand``).
        image.size = NSSize(width: bounds.width, height: max(0, bounds.height - Self.chromiumFrameBand))
        return image
    }

    /// `Page.captureScreenshot` for ``clearAreaSnapshot()``.
    nonisolated static var clearAreaSnapshotParams: [String: any Sendable] { ["format": "png", "optimizeForSpeed": true] }

    /// A small picture of the page as it last drew, at most `maxPixelWidth` pixels wide, its clear
    /// areas kept clear; nil when there is none. For a hover card: it does not wait for the next
    /// screen update (a parked page makes none).
    ///
    /// Chromium's is a PNG, not ``snapshot()``'s JPEG: a JPEG has no alpha, so a page's clear areas came
    /// out black and a light Markdown page's card showed a dark page (capture of 2026-11-11).
    ///
    /// The capture is of the viewport as it draws, with no `clip` (``pictureParams``), and is scaled down
    /// off the main actor here. A `clip` (with or without a `scale`) makes Chromium emulate another
    /// viewport for the capture (`EmulationHandler::SetDeviceEmulationParams`): the page on screen is laid
    /// out and rastered again, twice, and shows the bare page ground meanwhile. Every hover of a tab or
    /// workspace whose chat was on screen flashed the whole chat white for about a second (cmux#56141).
    ///
    /// - Parameter maxPixelWidth: The widest the picture may be, in pixels.
    /// - Returns: The picture, or nil when the page has no size or the engine gave none.
    public func picture(maxPixelWidth: CGFloat) async -> CGImage? {
        let size = bounds.size
        guard size.width >= 1, size.height >= 1 else { return nil }
        guard let page = chromiumSession?.page else {
            let configuration = WKSnapshotConfiguration()
            configuration.afterScreenUpdates = false
            configuration.snapshotWidth = NSNumber(value: Double(min(size.width, maxPixelWidth)))
            return (try? await webView.takeSnapshot(configuration: configuration))?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
        guard let json = try? await page.devTools("Page.captureScreenshot", params: Self.pictureParams),
              let data = await Self.screenshotData(json) else { return nil }
        return await Self.scaledPicture(data, maxPixelWidth: maxPixelWidth)
    }

    /// `Page.captureScreenshot` for ``picture(maxPixelWidth:)``: a fast-mode PNG of the viewport as it draws. Never a
    /// `clip` or `captureBeyondViewport`: either re-lays out the page on screen for the capture (cmux#56141).
    nonisolated static var pictureParams: [String: any Sendable] { ["format": "png", "optimizeForSpeed": true] }

    /// The picture in `data` (an encoded image) scaled to at most `maxPixelWidth` pixels wide, alpha kept, decoded off
    /// the main actor; nil when `data` holds no image.
    @concurrent nonisolated static func scaledPicture(_ data: Data, maxPixelWidth: CGFloat) async -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              width >= 1, height >= 1 else { return nil }
        let scale = min(1, Double(max(maxPixelWidth, 1)) / width)
        guard scale < 1 else { return CGImageSourceCreateImageAtIndex(source, 0, nil) }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, Int((max(width, height) * scale).rounded())),
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
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
        // Out of sight, the page draws for the wait (PageWebView+AwayDrawing).
        let heldAway = holdAwayDrawing()
        // task-owner: one frame wait; ends with the page's answer (or at once when the page is gone)
        Task { @MainActor [weak self] in
            guard let self else { return body() }
            _ = await self.callPageFunction(wait)
            defer { if heldAway { self.releaseAwayDrawing() } }
            guard self.chromiumSession == nil else { return body() }
            Self.afterPresentationUpdate(of: self.webView, body)
        }
    }

    /// Runs `body` once the page drew a frame laid out at `size` (points): its viewport reached that
    /// size, then the next frame. A Chromium page learns a new size from its window a frame or more
    /// after the view's, so a plain next frame can still be one at the old size. A frame not drawn
    /// within 50 ms (a throttled page) counts as one; gives up after 60 and runs `body` all the same.
    public func afterFrame(at size: CGSize, _ body: @escaping () -> Void) {
        let wait = """
        const fits = () => Math.abs(innerWidth - width) <= 1 && Math.abs(innerHeight - height) <= 1;
        const frame = () => new Promise((done) => { requestAnimationFrame(done); setTimeout(done, 50); });
        for (let count = 0; count < 60 && !fits(); count++) await frame();
        await frame();
        await new Promise((done) => setTimeout(done, 0));
        """
        let zoom = max(pageZoom, 0.01)
        // Out of sight, the page draws for the wait (PageWebView+AwayDrawing).
        let heldAway = holdAwayDrawing()
        // task-owner: bounded frame wait (at most 61 frames of 50 ms); ends with the page's answer (or at once when the page is gone)
        Task { @MainActor [weak self] in
            guard let self else { return body() }
            _ = await self.callPageFunction(wait, arguments: ["width": Double(size.width) / zoom, "height": Double(size.height) / zoom])
            defer { if heldAway { self.releaseAwayDrawing() } }
            guard self.chromiumSession == nil else { return body() }
            Self.afterPresentationUpdate(of: self.webView, body)
        }
    }

    /// Tells the Chromium page's window to follow this view now (it moved or was laid out again
    /// elsewhere): the window follows its view only when told (`CEFHostView.pagesNeedUpdate`).
    public func chromiumWindowMoved() {
        guard chromiumSession != nil, let window else { return }
        NotificationCenter.default.post(name: Notification.Name.browserChildWindowPagesNeedUpdate, object: window,
                                        userInfo: [browserPagesForceUpdateKey: true])
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
