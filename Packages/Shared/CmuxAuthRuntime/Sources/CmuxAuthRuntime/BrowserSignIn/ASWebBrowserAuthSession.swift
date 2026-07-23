internal import AuthenticationServices

/// Wraps one `ASWebAuthenticationSession` as a ``HostBrowserAuthSession``.
@MainActor
final class ASWebBrowserAuthSession: HostBrowserAuthSession {
    private let session: ASWebAuthenticationSession
    /// `ASWebAuthenticationSession` retains this provider weakly, so the
    /// attempt owns it for the full session lifetime.
    let presentationContextProvider: any ASWebAuthenticationPresentationContextProviding

    init(
        session: ASWebAuthenticationSession,
        presentationContextProvider: any ASWebAuthenticationPresentationContextProviding
    ) {
        self.session = session
        self.presentationContextProvider = presentationContextProvider
        session.presentationContextProvider = presentationContextProvider
    }

    func start() -> Bool {
        session.start()
    }

    func cancel() {
        session.cancel()
    }
}
