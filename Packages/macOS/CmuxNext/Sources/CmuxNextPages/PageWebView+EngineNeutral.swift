public import AppKit
import CmuxNextCompat
import CmuxNextWakeups
import Foundation
public import WebKit

// Calls a host makes on a page whichever engine shows it (WebKit, or Chromium through
// ``PageChromiumPage``), so a host never reaches into a WebKit view for them: a script,
// a picture of the page, the next drawn frame, and extra message handlers. None of them builds the
// WebKit engine: a Chromium page on its way answers nothing (PageWebKitEngine.swift). A function's value is
// ``PageWebView/callPageFunction(_:arguments:)``; in Chromium it runs through
// ``PageChromiumPage/evaluate(_:)``, which a CEF page answers with the fork's `tabEvaluate` on
// renderer paths (fork API 29), so there the frame wait makes no DevTools call.
extension PageWebView {
    /// Whether a Chromium page shows the document now (``engineDecision`` may still say Chromium
    /// while the page starts).
    public var showsChromium: Bool { chromiumSession != nil }

    /// The WebKit engine while it shows the page, for the WebKit-only tools (Web Inspector, the render
    /// rate, the WebContent process id); nil while Chromium shows it. Chrome's WebUI hosts reach the
    /// renderer only through `content::WebContents`, never a platform view
    /// (content/public/browser/web_contents.h): everything else here goes through the engine-neutral calls.
    public var webKitEngine: WKWebView? { showsChromium ? nil : webKitPieces?.view }

    /// The color under the page where it has not drawn: before its first paint and past its edges on
    /// a rubber-band scroll. WebKit draws it; a Chromium page is see-through there (``PageChromiumPage/setSeeThrough(_:)``),
    /// so the view under the page shows.
    /// A page with no WebKit view keeps it for the view a fallback builds.
    public var underPageColor: NSColor {
        get { webKitHooks.underPageColor }
        set { webKitHooks.underPageColor = newValue }
    }

    /// Drops the document for good after ``close()`` (not NSView's printing `endDocument()`), so its sockets and timers end now and not when
    /// the view is freed: a WebKit view that loaded stops and shows an empty document. A Chromium
    /// page ended with ``close()`` and has no WebKit view, and a WebKit view that never loaded has no
    /// process to end (an empty load would start one).
    public func endPageDocument() {
        guard let webView = webKitPieces?.view, webView.url != nil else { return }
        webView.stopLoading()
        webView.loadHTMLString("", baseURL: nil)
    }

    /// Runs `script` in the page's main frame, in whichever engine shows it, after the scripts sent
    /// before it. No result. A frozen page thaws first, or holds the latest push of a kind (``PageFrozenPush``).
    public func evaluate(_ script: String, whileFrozen push: PageFrozenPush = .thawsFirst) {
        pushes.run(script, whileFrozen: push)
    }

    /// A picture of the page as it draws now, at the view's size in points; nil when there is none.
    ///
    /// In Chromium it is a fast-mode JPEG: the browser encodes the capture on its UI thread, which
    /// is the app's main thread, and a full retina PNG took 80-140 ms there (see `CEFThumbnail`).
    /// The picture is a cover shown while the page draws again, so JPEG is plenty. The reply (a
    /// multi-megabyte base64 string) is parsed and decoded on the `.cpu` lane (``capturedPageImage(_:on:)``).
    public func snapshot() async -> NSImage? {
        guard !awaitsFirstShow else { return nil } // nothing drawn, and no engine call before the first show
        guard let session = chromiumSession else { return try? await webKitPieces?.view.takeSnapshot(configuration: nil) }
        guard let json = try? await session.page.devTools("Page.captureScreenshot", params: Self.snapshotParams),
              let image = await Self.capturedPageImage(json, on: session.work) else { return nil }
        return NSImage(cgImage: image, size: bounds.size)
    }

    /// Whether ``snapshot()`` keeps the page's clear areas the color the pane shows under them. A
    /// Chromium picture is a JPEG, with no alpha: a clear page comes out black, so it is no cover for a
    /// page that has not drawn yet (Cmd-T spam drew a black New Tab page, 2026-10-24).
    public var snapshotKeepsClearAreas: Bool { chromiumSession == nil }

    /// `Page.captureScreenshot` for ``snapshot()``.
    nonisolated static var snapshotParams: [String: any Sendable] { ["format": "jpeg", "quality": 85, "optimizeForSpeed": true] }

    /// The image of a `Page.captureScreenshot` reply, parsed and decoded on `work`'s `.cpu` lane at the caller's
    /// priority (a full window is megabytes, far above the main-thread image gate), so the main actor only wraps the
    /// pixels. Chrome decodes such images in its data decoder service, off the UI thread
    /// (services/data_decoder/public/cpp/decode_image.h). Nil when the reply holds no image or the lanes shut down.
    ///
    /// - Parameters:
    ///   - json: The method's JSON result.
    ///   - work: The app's lanes.
    /// - Returns: The decoded image.
    nonisolated static func capturedPageImage(_ json: String, on work: BackgroundWork) async -> CGImage? {
        try? await work.run(WorkPriority(Task.currentPriority), mayBlock: .cpu) { Self.capturedPageImage(json) }
    }

    /// The image of a `Page.captureScreenshot` reply, parsed and decoded on the calling thread.
    nonisolated static func capturedPageImage(_ json: String) -> CGImage? {
        guard let object = ChromiumPageHostWire.object(json), let base64 = object["data"] as? String,
              let data = Data(base64Encoded: base64) else { return nil }
        return blockingImageDecode(data)
    }

    /// Runs `body` once the page drew its next frame: an animation frame and a task in the page, then
    /// (WebKit) the next presentation update the window shows. Now when the page is gone.
    public func afterNextFrame(_ body: @escaping () -> Void) {
        let wait = "await new Promise((done) => requestAnimationFrame(() => setTimeout(done, 0)));"
        // task-owner: one frame wait; ends with the page's answer (or at once when the page is gone)
        Task { @MainActor [weak self] in
            guard let self, !self.awaitsFirstShow else { return body() }
            _ = await self.callPageFunction(wait)
            guard self.chromiumSession == nil, let view = self.webKitPieces?.view else { return body() }
            Self.afterPresentationUpdate(of: view, body)
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
        let controller = userContent
        controller.removeScriptMessageHandler(forName: name, contentWorld: .page)
        controller.add(PageMessageRelay(view: self, handler: handler), contentWorld: .page, name: name)
    }

    /// Removes a handler ``addMessageHandler(_:handler:)`` added.
    public func removeMessageHandler(_ name: String) {
        chromiumMessageHandlers[name] = nil
        userContent.removeScriptMessageHandler(forName: name, contentWorld: .page)
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
        guard let view, let webView = message.webView, webView === view.webKitPieces?.view, message.frameInfo.isMainFrame else { return }
        handler(message.body)
    }
}
