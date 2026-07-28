import Foundation
import WebKit

/// Receives `{ frameID, playing, audible }` from the injected media-playback hook and
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
        let audible = body["audible"] as? Bool ?? false
        let report = BrowserMediaPlaybackReport(frameID: frameID, isPlaying: playing, isAudible: audible)
        // WebKit delivers script messages on the main thread. Apply the report
        // synchronously instead of hopping through a `Task` so it lands in
        // WebKit's delivery order relative to navigation callbacks: a report
        // emitted by a document before it navigates away is applied before the
        // matching `didCommit` reset, so a stale `playing: true` cannot re-add a
        // dead frame id after the reset and pin the pane against discard.
        MainActor.assumeIsolated {
            onReport(report)
        }
    }
}
