import Foundation
import WebKit

/// Receives `{ frameID, playing }` from the injected media-playback hook and
/// forwards it to the owning ``BrowserPanel`` on the main actor.
///
/// Mirrors ``ReactGrabMessageHandler``: a thin `NSObject` adapter so the panel
/// itself never has to conform to `WKScriptMessageHandler`.
final class BrowserMediaPlaybackMessageHandler: NSObject, WKScriptMessageHandler {
    private let onReport: @MainActor (BrowserMediaPlaybackReport) -> Void

    init(onReport: @escaping @MainActor (BrowserMediaPlaybackReport) -> Void) {
        self.onReport = onReport
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? [String: Any],
              let frameID = body["frameID"] as? String,
              let playing = body["playing"] as? Bool else { return }
        let report = BrowserMediaPlaybackReport(frameID: frameID, isPlaying: playing)
        Task { @MainActor in
            onReport(report)
        }
    }
}
