public import Foundation
public import WebKit

/// Receives `{ frameID, playing, audible, pip }` from the injected media-playback hook and
/// forwards it to the owning ``BrowserPanel`` on the main actor.
///
/// Mirrors ``ReactGrabMessageHandler``: a thin `NSObject` adapter so the panel
/// itself never has to conform to `WKScriptMessageHandler`. It is bound to one
/// web view: a popup the page opens is built from the opener's configuration
/// and shares its content controller, so the popup's reports reach this handler
/// too and are dropped.
@MainActor
public final class BrowserMediaPlaybackMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var webView: WKWebView?
    private let onReport: @MainActor (BrowserMediaPlaybackReport) -> Void

    public init(
        webView: WKWebView,
        onReport: @escaping @MainActor (BrowserMediaPlaybackReport) -> Void
    ) {
        self.webView = webView
        self.onReport = onReport
    }

    public nonisolated func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        Task { @MainActor [weak self] in
            self?.handle(message: message)
        }
    }

    private func handle(message: WKScriptMessage) {
        guard message.webView === webView,
              let body = message.body as? [String: Any],
              let frameID = body["frameID"] as? String,
              let playing = body["playing"] as? Bool else { return }
        let report = BrowserMediaPlaybackReport(
            frameID: frameID,
            isPlaying: playing,
            isAudible: body["audible"] as? Bool ?? false,
            isPictureInPicture: body["pip"] as? Bool ?? false
        )
        // WebKit delivers script messages on the main thread, but does not
        // install Swift's executor token. MainActor tasks preserve callback
        // order with navigation work and generation checks drop stale reports.
        onReport(report)
    }
}
