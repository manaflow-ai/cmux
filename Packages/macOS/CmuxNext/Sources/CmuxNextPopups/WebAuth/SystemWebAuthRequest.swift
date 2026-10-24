import AuthenticationServices

/// A sign-in request from another app's `ASWebAuthenticationSession`, which
/// macOS hands cmux as the default browser.
@MainActor
final class SystemWebAuthRequest: WebAuthSessionRequest {
    let request: ASWebAuthenticationSessionRequest
    let id: UUID
    let url: URL
    let isEphemeral: Bool
    let callback: WebAuthCallback

    init(_ request: ASWebAuthenticationSessionRequest) {
        self.request = request
        id = request.uuid
        url = request.url
        isEphemeral = request.shouldUseEphemeralSession
        if #available(macOS 14.4, *) {
            callback = Self.callback(of: request.callback)
        } else {
            // macOS 14.0-14.3 report only a custom scheme.
            callback = request.callbackURLScheme.map { .customScheme($0) } ?? .none
        }
    }

    /// The scheme, or the https host and path, of the system's callback. It
    /// keeps them in properties it does not publish; the shim needs them to
    /// stop the callback navigation before it loads. Unknown (`.none`) when
    /// they cannot be read: the system's own matcher still ends the session
    /// once the tab shows the callback (`WebAuthSessionWindow`).
    @available(macOS 14.4, *)
    static func callback(of callback: ASWebAuthenticationSession.Callback?) -> WebAuthCallback {
        guard let object = callback as NSObject? else { return .none }
        func string(_ key: String) -> String? {
            // crash-allow: value(forKey:) runs only after responds(to:) found the getter, so an unknown key cannot raise
            guard object.responds(to: NSSelectorFromString(key)), let value = object.value(forKey: key) as? String,
                  !value.isEmpty else { return nil }
            return value
        }
        if let scheme = string("customScheme") { return .customScheme(scheme) }
        if let host = string("host") { return .https(host: host, path: string("path") ?? "/") }
        return .none
    }

    /// The system's matcher decides; `callback` only when there is none.
    func matches(_ url: URL) -> Bool {
        if #available(macOS 14.4, *), let system = request.callback { return system.matchesURL(url) }
        return callback.matches(url)
    }

    func complete(with url: URL) {
        request.complete(withCallbackURL: url)
    }

    func cancel() {
        request.cancelWithError(ASWebAuthenticationSessionError(.canceledLogin))
    }
}
