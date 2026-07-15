import Foundation
import WebKit

/// Converts WebKit message bodies to Sendable data before entering the UI owner.
final class BrowserDesignModeMessageHandler: NSObject, WKScriptMessageHandler {
    static let name = "cmuxDesignMode"
    private static let maximumRequestedChangeBytes = 16 * 1_024

    private let onSnapshot: @MainActor @Sendable (Data) -> Void
    private let onCopy: @MainActor @Sendable (String) -> Void

    init(
        onSnapshot: @escaping @MainActor @Sendable (Data) -> Void,
        onCopy: @escaping @MainActor @Sendable (String) -> Void
    ) {
        self.onSnapshot = onSnapshot
        self.onCopy = onCopy
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == Self.name,
              message.frameInfo.isMainFrame,
              let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }
        switch type {
        case "snapshot":
            guard let snapshot = body["snapshot"],
                  JSONSerialization.isValidJSONObject(snapshot),
                  let data = try? JSONSerialization.data(withJSONObject: snapshot) else { return }
            MainActor.assumeIsolated { [onSnapshot] in
                onSnapshot(data)
            }
        case "copy":
            guard let rawRequest = body["requested_change"] as? String,
                  rawRequest.utf8.count <= Self.maximumRequestedChangeBytes else { return }
            let request = rawRequest.trimmingCharacters(in: .whitespacesAndNewlines)
            MainActor.assumeIsolated { [onCopy] in
                onCopy(request)
            }
        default:
            return
        }
    }
}
