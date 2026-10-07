public import Foundation
public import WebKit

public final class BrowserSSLTrustBypassMessageHandler: NSObject, WKScriptMessageHandler {
    public static let name = "cmuxSSLTrustBypass"

    private let canHandleToken: @MainActor (String) -> Bool
    private let handleToken: @MainActor (String) -> Void

    public init(
        canHandleToken: @escaping @MainActor (String) -> Bool,
        handleToken: @escaping @MainActor (String) -> Void
    ) {
        self.canHandleToken = canHandleToken
        self.handleToken = handleToken
    }

    public func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == Self.name,
              message.frameInfo.isMainFrame,
              let token = Self.validToken(from: message.body) else {
            return
        }

        // WebKit delivers script messages on the main thread, but that callback
        // does not carry Swift's MainActor executor token. Hop explicitly before
        // touching the actor-bound owner and re-check the token there.
        Task { @MainActor [canHandleToken, handleToken] in
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
