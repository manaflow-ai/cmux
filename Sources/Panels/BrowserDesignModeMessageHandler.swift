import Foundation
import WebKit

/// Converts WebKit message bodies to Sendable data before entering the UI owner.
final class BrowserDesignModeMessageHandler: NSObject, WKScriptMessageHandler {
    static let name = "cmuxDesignMode"

    private let onSnapshot: @MainActor @Sendable (Data) -> Void
    private let onExitRequested: @MainActor @Sendable () -> Void
    private let onPromptReset: @MainActor @Sendable () -> Void

    init(
        onSnapshot: @escaping @MainActor @Sendable (Data) -> Void,
        onExitRequested: @escaping @MainActor @Sendable () -> Void = {},
        onPromptReset: @escaping @MainActor @Sendable () -> Void = {}
    ) {
        self.onSnapshot = onSnapshot
        self.onExitRequested = onExitRequested
        self.onPromptReset = onPromptReset
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == Self.name,
              message.frameInfo.isMainFrame,
              let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }
        if type == "exit_requested" {
            MainActor.assumeIsolated { [onExitRequested] in
                onExitRequested()
            }
            return
        }
        if type == "prompt_reset" {
            MainActor.assumeIsolated { [onPromptReset] in
                onPromptReset()
            }
            return
        }
        guard type == "snapshot",
              let snapshot = body["snapshot"],
              JSONSerialization.isValidJSONObject(snapshot),
              let data = try? JSONSerialization.data(withJSONObject: snapshot) else { return }
        MainActor.assumeIsolated { [onSnapshot] in
            onSnapshot(data)
        }
    }
}
