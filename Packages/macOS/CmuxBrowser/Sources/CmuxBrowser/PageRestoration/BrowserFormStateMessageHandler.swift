public import Foundation
public import WebKit

/// Receives unsaved form input from the injected ``BrowserFormStateScript``
/// observer and forwards it to the owning panel on the main actor.
///
/// Mirrors ``BrowserMediaPlaybackMessageHandler``: a thin `NSObject` adapter
/// so the panel never conforms to `WKScriptMessageHandler` itself.
public final class BrowserFormStateMessageHandler: NSObject, WKScriptMessageHandler {
    private let onReport: @MainActor (BrowserFormStateSnapshot) -> Void

    public init(onReport: @escaping @MainActor (BrowserFormStateSnapshot) -> Void) {
        self.onReport = onReport
    }

    public func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.frameInfo.isMainFrame,
              let snapshot = BrowserFormStateSnapshot(messageBody: message.body) else { return }
        // WebKit delivers script messages on the main thread, in order with
        // navigation callbacks, so a report sent by a document before it
        // navigates away lands before the next document's commit resets it.
        MainActor.assumeIsolated {
            onReport(snapshot)
        }
    }
}
