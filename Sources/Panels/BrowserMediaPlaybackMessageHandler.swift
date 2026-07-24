import Foundation
import WebKit

/// Receives `{ frameID, playing, audible }` from the injected media-playback hook and
/// forwards it to the owning ``BrowserPanel`` on the main actor.
///
/// Mirrors ``ReactGrabMessageHandler``: a thin `NSObject` adapter so the panel
/// itself never has to conform to `WKScriptMessageHandler`.
// WebKit invokes both methods on its main run loop. The unchecked conformance
// lets the MainActor delivery task capture the handler solely to compare the
// main-thread-confined document generation.
final class BrowserMediaPlaybackMessageHandler: NSObject, WKScriptMessageHandler, @unchecked Sendable {
    private let onReport: @MainActor (BrowserMediaPlaybackReport) -> Void
    private var documentGeneration = 0

    init(onReport: @escaping @MainActor (BrowserMediaPlaybackReport) -> Void) {
        self.onReport = onReport
    }

    /// Invalidates reports queued by the document that just navigated away.
    func noteMainFrameNavigationCommit() {
        guard Thread.isMainThread else { return }
        documentGeneration &+= 1
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
        guard Thread.isMainThread else { return }
        let generation = documentGeneration
        Task { @MainActor [weak self, onReport] in
            guard self?.documentGeneration == generation else { return }
            onReport(report)
        }
    }
}
