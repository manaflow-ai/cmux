public import Foundation

/// Runs the auth socket commands against the shared auth runtime.
@MainActor
public final class AuthSocketCommandService {
    private let coordinator: AuthCoordinator?
    private let browserSignIn: HostBrowserSignInFlow?

    /// Creates an auth socket command service.
    ///
    /// - Parameters:
    ///   - coordinator: The shared auth coordinator, when the app graph is attached.
    ///   - browserSignIn: The hosted-browser sign-in flow, when the app graph is attached.
    public init(coordinator: AuthCoordinator?, browserSignIn: HostBrowserSignInFlow?) {
        self.coordinator = coordinator
        self.browserSignIn = browserSignIn
    }

    /// Returns the current `auth.status` payload after launch restore has settled.
    ///
    /// - Parameter timedOut: Whether the caller's bounded wait timed out.
    public func status(timedOut: Bool) async -> AuthSocketStatusPayload {
        await coordinator?.awaitBootstrapped()
        return statusSnapshot(timedOut: timedOut)
    }

    /// Returns the hosted sign-in URL payload.
    public func signInURL() -> AuthSocketSignInURLPayload {
        AuthSocketSignInURLPayload(url: browserSignIn?.manualSignInURL.absoluteString)
    }

    /// Runs `auth.begin_sign_in` and returns the post-attempt auth status payload.
    ///
    /// - Parameter timeoutSeconds: The caller-specified deadline in seconds.
    public func beginSignIn(timeoutSeconds: TimeInterval) async -> AuthSocketStatusPayload {
        let signedIn = await browserSignIn?.signIn(timeout: timeoutSeconds) ?? false
        return statusSnapshot(timedOut: !signedIn)
    }

    /// Runs `auth.sign_out` and returns the post-sign-out auth status payload.
    ///
    /// - Parameter timeoutSeconds: The deadline in seconds for the socket caller.
    public func signOut(timeoutSeconds: TimeInterval) async -> AuthSocketStatusPayload {
        await browserSignIn?.signOut(timeout: timeoutSeconds)
        return statusSnapshot(timedOut: false)
    }

    private func statusSnapshot(timedOut: Bool) -> AuthSocketStatusPayload {
        AuthSocketStatusPayload(
            coordinator: coordinator,
            isSigningIn: browserSignIn?.isSigningIn ?? false,
            timedOut: timedOut
        )
    }
}
