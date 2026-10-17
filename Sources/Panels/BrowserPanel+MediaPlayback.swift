import CmuxBrowser
import Foundation
import WebKit

/// Name of the `WKScriptMessageHandler` the injected media-playback hook posts to.
private let mediaPlaybackMessageHandlerName = "cmuxMediaPlayback"

extension BrowserPanel {
    /// Isolated content world for the media-playback hook.
    ///
    /// Both the injected script and the message handler live here, not the page
    /// world, so arbitrary page JavaScript cannot reach
    /// the private media-playback message handler and post a fake `{ playing:
    /// true }` report that would pin the pane alive forever and defeat
    /// hidden-webview discard. A content world shares the DOM, so the script's
    /// media event listeners and `MutationObserver` still observe page playback.
    static let mediaPlaybackContentWorld = WKContentWorld.world(name: mediaPlaybackMessageHandlerName)

    /// The shared media-playback hook (``BrowserMediaPlaybackScript``),
    /// posting to this panel's isolated-world message handler.
    static let mediaPlaybackTrackingBootstrapScriptSource = BrowserMediaPlaybackScript.source(
        post: "window.webkit.messageHandlers[\"\(mediaPlaybackMessageHandlerName)\"].postMessage(report)"
    )

    /// Reports `<video>`/`<audio>` playback so a hidden pane with actively-playing
    /// media is exempted from memory discard
    /// (https://github.com/manaflow-ai/cmux/issues/5409). Injected into every
    /// frame so embedded players in cross-origin iframes keep the pane alive
    /// too. Runs in an isolated content world (shared DOM, separate JS scope)
    /// so the handler is hidden from page JavaScript that could otherwise post
    /// a fake playing report; this also keeps it clear of CAPTCHA fingerprint
    /// checks in those iframes.
    static func installMediaPlaybackUserScript(into configuration: WKWebViewConfiguration) {
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: mediaPlaybackTrackingBootstrapScriptSource,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false,
                in: mediaPlaybackContentWorld
            )
        )
    }

    /// Installs the media-playback message handler on `webView`.
    ///
    /// Each `BrowserPanel` webview is created with a fresh `WKWebViewConfiguration`
    /// (`makeWebView`), so the handler name is never registered twice on one
    /// content controller. Reset media tracking for the freshly bound webview.
    func setupMediaPlaybackMessageHandler(for webView: WKWebView) {
        resetMediaPlaybackTracking()
        // Bind the handler to this webview generation. The handler stays alive on
        // the old content controller until the old webview deallocates, so a late
        // report from a replaced document must be ignored or it would repopulate
        // mediaPlaybackFrames for a page that is gone and block discard forever.
        let boundWebViewInstanceID = webViewInstanceID
        let handler = BrowserMediaPlaybackMessageHandler(webView: webView) { [weak self] report in
            self?.handleMediaPlaybackReport(report, fromWebViewInstanceID: boundWebViewInstanceID)
        }
        mediaPlaybackMessageHandler = handler
        webView.configuration.userContentController.add(
            handler,
            contentWorld: Self.mediaPlaybackContentWorld,
            name: mediaPlaybackMessageHandlerName
        )
    }

    func tearDownMediaPlaybackMessageHandler(for webView: WKWebView) {
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: mediaPlaybackMessageHandlerName,
            contentWorld: Self.mediaPlaybackContentWorld
        )
        mediaPlaybackMessageHandler = nil
        resetMediaPlaybackTracking()
    }

    /// Applies a per-frame playback report from the injected hook, aggregating
    /// across the main frame and any iframes. Reports from a superseded webview
    /// generation are dropped.
    func handleMediaPlaybackReport(
        _ report: BrowserMediaPlaybackReport,
        fromWebViewInstanceID instanceID: UUID
    ) {
        guard instanceID == webViewInstanceID else { return }
        applyMediaPlaybackReport(report)
#if DEBUG
        cmuxDebugLog(
            "browser.media.playback panel=\(id.uuidString.prefix(5)) " +
            "frame=\(report.frameID.prefix(5)) playing=\(report.isPlaying ? 1 : 0) " +
            "audible=\(report.isAudible ? 1 : 0) pip=\(report.isPictureInPicture ? 1 : 0) " +
            "anyPlaying=\(isPlayingMedia ? 1 : 0) " +
            "anyAudible=\(isPlayingAudio ? 1 : 0)"
        )
#endif
    }
}
