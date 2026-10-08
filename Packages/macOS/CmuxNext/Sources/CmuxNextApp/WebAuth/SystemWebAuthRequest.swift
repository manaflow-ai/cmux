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
        callback = Self.callback(of: request.callback)
    }

    /// The scheme, or the https host and path, of the system's callback. It
    /// keeps them in properties it does not publish; the shim needs them to
    /// stop the callback navigation before it loads. Unknown (`.none`) when
    /// they cannot be read: the system's own matcher still ends the session
    /// once the tab shows the callback (`WebAuthSessionWindows`).
    static func callback(of callback: ASWebAuthenticationSession.Callback?) -> WebAuthCallback {
        guard let object = callback as NSObject? else { return .none }
        func string(_ key: String) -> String? {
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
        request.callback?.matchesURL(url) ?? callback.matches(url)
    }

    func complete(with url: URL) {
        request.complete(withCallbackURL: url)
    }

    func cancel() {
        request.cancelWithError(ASWebAuthenticationSessionError(.canceledLogin))
    }
}

/// The system's session handler (`ASWebAuthenticationSessionWebBrowserSessionManager`).
/// macOS calls it on its own queue; every request goes to the broker on the
/// main actor.
final class WebAuthSessionHandler: NSObject, ASWebAuthenticationSessionWebBrowserSessionHandling {
    private let broker: WebAuthSessionBroker

    @MainActor
    init(broker: WebAuthSessionBroker) {
        self.broker = broker
    }

    /// Installs `handler` as the app's session handler (once, at launch:
    /// macOS delivers a request that launched cmux after this).
    @MainActor
    static func install(_ handler: WebAuthSessionHandler) {
        ASWebAuthenticationSessionWebBrowserSessionManager.shared.sessionHandler = handler
    }

    func begin(_ request: ASWebAuthenticationSessionRequest!) {
        guard let request else { return }
        nonisolated(unsafe) let unsafeRequest = request
        let broker = broker
        Task { @MainActor in broker.begin(SystemWebAuthRequest(unsafeRequest)) }
    }

    func cancel(_ request: ASWebAuthenticationSessionRequest!) {
        guard let request else { return }
        let id = request.uuid
        let broker = broker
        Task { @MainActor in broker.systemCancelled(id) }
    }
}
