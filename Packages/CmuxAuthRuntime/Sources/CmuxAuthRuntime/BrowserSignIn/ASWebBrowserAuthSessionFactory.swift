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
        let debugLog = log
        let session = ASWebAuthenticationSession(
            url: signInURL,
            callbackURLScheme: callbackScheme
        ) { callbackURL, error in
            // ASWebAuthenticationSession invokes this on the thread that
            // started it (always main here); hop explicitly so the contract
            // holds even if AppKit changes that.
            Task { @MainActor in
                if let error {
                    debugLog.log("auth.webauth failed: \(error)")
                }
                completion(callbackURL)
            }
        }
        session.presentationContextProvider = anchor
        session.prefersEphemeralWebBrowserSession = false
        return ASWebBrowserAuthSession(session: session)
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
