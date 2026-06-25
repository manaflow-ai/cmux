import Foundation
import WebKit

final class BrowserSSLTrustBypassMessageHandler: NSObject, WKScriptMessageHandler {
    static let name = "cmuxSSLTrustBypass"

    private let handleActionURL: @MainActor (URL) -> Void

    init(handleActionURL: @escaping @MainActor (URL) -> Void) {
        self.handleActionURL = handleActionURL
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == Self.name,
              let token = Self.token(from: message.body) else {
            return
        }

        var components = URLComponents()
        components.scheme = "cmux-browser-action"
        components.host = "bypass-ssl"
        components.queryItems = [
            URLQueryItem(name: "token", value: token),
        ]

        guard let actionURL = components.url else { return }
        Task { @MainActor in
            handleActionURL(actionURL)
        }
    }

    private static func token(from body: Any) -> String? {
        if let token = body as? String, !token.isEmpty {
            return token
        }

        if let payload = body as? [String: Any],
           let token = payload["token"] as? String,
           !token.isEmpty {
            return token
        }

        return nil
    }
}
