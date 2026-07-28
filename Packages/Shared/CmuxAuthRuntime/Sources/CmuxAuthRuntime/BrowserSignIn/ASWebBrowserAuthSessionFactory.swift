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
        completion: @escaping @MainActor (HostBrowserAuthSessionResult) -> Void
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
        completion: @escaping @MainActor (HostBrowserAuthSessionResult) -> Void
    ) -> @Sendable (URL?, (any Error)?) -> Void {
        let log = self.log
        return { callbackURL, error in
            let result = self.sessionResult(callbackURL: callbackURL, error: error)
            Task { @MainActor in
                if let error {
                    let nsError = error as NSError
                    log.log("auth.webauth.completion errorDomain=\(nsError.domain) errorCode=\(nsError.code) callback=\(callbackURL == nil ? "nil" : "present")")
                    log.log("auth.webauth failed: \(error)")
                } else {
                    log.log("auth.webauth.completion error=nil callback=\(callbackURL == nil ? "nil" : "present")")
                }
                completion(result)
            }
        }
    }

    nonisolated private func sessionResult(
        callbackURL: URL?,
        error: (any Error)?
    ) -> HostBrowserAuthSessionResult {
        if let callbackURL {
            return .callback(callbackURL)
        }
        guard let error else {
            return .failed(reason: "missing_callback")
        }
        let nsError = error as NSError
        if nsError.domain == ASWebAuthenticationSessionError.errorDomain {
            switch nsError.code {
            case ASWebAuthenticationSessionError.Code.canceledLogin.rawValue:
                return .cancelled(reason: "canceled_login")
            case ASWebAuthenticationSessionError.Code.presentationContextInvalid.rawValue:
                return .failed(reason: "presentation_context_invalid")
            case ASWebAuthenticationSessionError.Code.presentationContextNotProvided.rawValue:
                return .failed(reason: "presentation_context_not_provided")
            default:
                return .failed(reason: "aswebauthentication_\(nsError.code)")
            }
        }
        if nsError.domain == NSURLErrorDomain {
            return .failed(reason: "network_\(nsError.code)")
        }
        return .failed(reason: "error_\(nsError.code)")
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
