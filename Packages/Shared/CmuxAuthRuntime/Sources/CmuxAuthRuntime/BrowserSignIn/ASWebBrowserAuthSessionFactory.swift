public import AuthenticationServices
public import Foundation

/// The production ``HostBrowserAuthSessionFactory``, backed by
/// `ASWebAuthenticationSession` presenting from the injected anchor provider.
@MainActor
public final class ASWebBrowserAuthSessionFactory: HostBrowserAuthSessionFactory {
    private let anchor: any ASWebAuthenticationPresentationContextProviding
    private let log = AuthDebugLog()

    /// Creates the factory.
    /// - Parameter anchor: The presentation anchor provider (production:
    ///   ``AuthPresentationContextProvider``).
    public init(anchor: any ASWebAuthenticationPresentationContextProviding) {
        self.anchor = anchor
    }

    public func makeSession(
        signInURL: URL,
        callbackScheme: String,
        completion: @escaping @MainActor (URL?) -> Void
    ) -> any HostBrowserAuthSession {
        log.log("auth.webauth.makeSession signInURL=\(signInURL.absoluteString) callbackScheme=\(callbackScheme)")
        let session = ASWebAuthenticationSession(
            url: signInURL,
            callbackURLScheme: callbackScheme,
            completionHandler: sessionCompletionBridge(completion: completion)
        )
        session.presentationContextProvider = anchor
        session.prefersEphemeralWebBrowserSession = false
        return ASWebBrowserAuthSession(session: session)
    }

    /// The completion handed to `ASWebAuthenticationSession`.
    ///
    /// Deliberately `nonisolated` + `@Sendable`: the session does NOT reliably
    /// call back on the main thread (observed on macOS 26: the cancel path
    /// delivers on the `SafariLaunchAgent` NSXPCConnection queue). A closure
    /// formed in this class's `@MainActor` context would inherit main-actor
    /// isolation and Swift 6 would trap (`dispatch_assert_queue`) at the ObjC
    /// boundary when that off-main delivery happens. This bridge carries no
    /// isolation assumption and hops to the main actor itself.
    nonisolated func sessionCompletionBridge(
        completion: @escaping @MainActor (URL?) -> Void
    ) -> @Sendable (URL?, (any Error)?) -> Void {
        let log = self.log
        return { callbackURL, error in
            Task { @MainActor in
                if let error {
                    let nsError = error as NSError
                    log.log("auth.webauth.completion errorDomain=\(nsError.domain) errorCode=\(nsError.code) callback=\(callbackURL == nil ? "nil" : "present")")
                    log.log("auth.webauth failed: \(error)")
                } else {
                    log.log("auth.webauth.completion error=nil callback=\(callbackURL == nil ? "nil" : "present")")
                }
                completion(callbackURL)
            }
        }
    }
}

/// Wraps one `ASWebAuthenticationSession` as a ``HostBrowserAuthSession``.
@MainActor
private final class ASWebBrowserAuthSession: HostBrowserAuthSession {
    private let session: ASWebAuthenticationSession

    init(session: ASWebAuthenticationSession) {
        self.session = session
    }

    func start() -> Bool {
        session.start()
    }

    func cancel() {
        session.cancel()
    }
}
