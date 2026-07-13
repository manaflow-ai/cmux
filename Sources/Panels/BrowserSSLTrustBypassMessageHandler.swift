import Foundation
import WebKit

final class BrowserSSLTrustBypassMessageHandler: NSObject, WKScriptMessageHandler {
    static let name = "cmuxSSLTrustBypass"

    private let canHandleToken: @MainActor (String) -> Bool
    private let handleToken: @MainActor (String) -> Void

    init(
        canHandleToken: @escaping @MainActor (String) -> Bool,
        handleToken: @escaping @MainActor (String) -> Void
    ) {
        self.canHandleToken = canHandleToken
        self.handleToken = handleToken
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == Self.name,
              message.frameInfo.isMainFrame,
              let token = Self.validToken(from: message.body) else {
            return
        }

        // WebKit delivers script messages on the main thread. Keep token gating
        // synchronous so hostile content cannot enqueue unbounded main-actor work
        // before the owner rejects stale or mismatched bypass attempts.
        MainActor.assumeIsolated { [canHandleToken, handleToken] in
            guard canHandleToken(token) else { return }
            handleToken(token)
        }
    }

    private static func validToken(from body: Any) -> String? {
        if let token = body as? String,
           token.count == 36,
           UUID(uuidString: token) != nil {
            return token
        }

        return nil
    }
}
