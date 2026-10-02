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

    public func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
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
        // WebKit delivers script messages on the main thread. Apply the report
        // synchronously instead of hopping through a `Task` so it lands in
        // WebKit's delivery order relative to navigation callbacks: a report
        // emitted by a document before it navigates away is applied before the
        // matching `didCommit` reset, so a stale `playing: true` cannot re-add a
        // dead frame id after the reset and pin the pane against discard.
        onReport(report)
    }
}
