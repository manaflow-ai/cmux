public import Foundation
public import Observation

/// The macOS hosted-browser sign-in flow.
///
/// Drives one `ASWebAuthenticationSession` attempt at a time against the cmux
/// web app's hosted sign-in page, then seeds the callback tokens into the
/// injected token store and publishes the session through the shared
/// ``AuthCoordinator`` (`completeExternalSignIn()`). Also handles auth
/// callback URLs that arrive through the app's URL scheme outside a popup.
/// Owns the attempt/sign-out race guards so a late browser callback can never
/// resurrect a session the user just signed out of.
@MainActor
@Observable
public final class HostBrowserSignInFlow {
    /// Whether a browser sign-in attempt (popup + completion) is in flight.
    public private(set) var isSigningIn = false

    private let coordinator: AuthCoordinator
    private let tokenStore: any StackAuthTokenStoreProtocol
    private let sessionFactory: any HostBrowserAuthSessionFactory
    private let callbackRouter: AuthCallbackRouter
    private let makeSignInURL: @MainActor () -> URL
    private let callbackScheme: @MainActor () -> String
    private let clock: any Clock<Duration>
    private let log = AuthDebugLog()

    @ObservationIgnored private var activeSession: (any HostBrowserAuthSession)?
    @ObservationIgnored private var nextAttemptID: UInt64 = 0
    @ObservationIgnored private var activeAttemptID: UInt64?
    @ObservationIgnored private var signOutGeneration: UInt64 = 0

    /// Creates the flow.
    /// - Parameters:
    ///   - coordinator: The shared auth coordinator that owns session state.
    ///   - tokenStore: The store the `StackClientApp` reads tokens from; the
    ///     callback tokens are seeded here.
    ///   - sessionFactory: Browser-session seam (production:
    ///     ``ASWebBrowserAuthSessionFactory``).
    ///   - callbackRouter: Recognizes/parses auth callback URLs.
    ///   - makeSignInURL: Builds the hosted sign-in URL per attempt (the
    ///     composition root derives it from its environment table).
    ///   - callbackScheme: The custom callback scheme for the popup.
    ///   - clock: Drives the sign-in deadline; tests inject a virtual clock.
    public init(
        coordinator: AuthCoordinator,
        tokenStore: any StackAuthTokenStoreProtocol,
        sessionFactory: any HostBrowserAuthSessionFactory,
        callbackRouter: AuthCallbackRouter,
        makeSignInURL: @escaping @MainActor () -> URL,
        callbackScheme: @escaping @MainActor () -> String,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.coordinator = coordinator
        self.tokenStore = tokenStore
        self.sessionFactory = sessionFactory
        self.callbackRouter = callbackRouter
        self.makeSignInURL = makeSignInURL
        self.callbackScheme = callbackScheme
        self.clock = clock
    }

    /// Start a browser sign-in without awaiting the result (Settings button).
    /// Cancels any previous attempt's popup first.
    public func beginSignIn() {
        _ = startAttempt()
    }

    /// Run a browser sign-in attempt with a deadline, for the socket
    /// `auth.begin_sign_in` command. Returns whether the app ended signed in
    /// before the deadline; the popup itself stays up past the deadline so the
    /// user can still finish.
    public func signIn(timeout: TimeInterval) async -> Bool {
        if coordinator.isAuthenticated { return true }
        return await awaitWithDeadline(startAttempt(), timeout: timeout)
    }

    /// Handle an auth callback URL delivered through the app's URL scheme
    /// (e.g. the hosted page redirected in the user's real browser instead of
    /// the popup). Returns whether the app ended signed in.
    @discardableResult
    public func handleCallbackURL(_ url: URL) async -> Bool {
        await completeCallback(url: url, attemptID: nil)
    }

    /// Sign out, cancelling any in-flight browser attempt so a late callback
    /// can't resurrect the session.
    public func signOut() async {
        signOutGeneration &+= 1
        cancelActiveAttempt()
        await coordinator.signOut()
    }

    /// Sign out with a deadline, for the socket `auth.sign_out` command. The
    /// sign-out itself always runs to completion in the background; the
    /// deadline only caps how long the socket caller can hang on the network
    /// revoke round trip.
    public func signOut(timeout: TimeInterval) async {
        // Strong capture on purpose: the user asked to sign out, so the task
        // must keep the flow alive until the sign-out completes even if the
        // socket caller stops waiting at the deadline.
        let attempt = Task { @MainActor in
            await self.signOut()
            return true
        }
        _ = await awaitWithDeadline(attempt, timeout: timeout)
    }

    /// Await `attempt`, resolving `false` at the deadline while the attempt
    /// keeps running in the background.
    ///
    /// Deadline, not polling: bounded + cancellable (cancelled as soon as the
    /// attempt resolves), virtual-clock testable via the injected clock.
    private func awaitWithDeadline(_ attempt: Task<Bool, Never>, timeout: TimeInterval) async -> Bool {
        // Clamp before converting so an oversized Double can't overflow.
        let clamped = max(0, min(timeout, 24 * 60 * 60))
        let clock = self.clock
        let deadlineTask = Task { try await clock.sleep(for: .seconds(clamped)) }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let once = ResumeOnceFlag()
            Task { @MainActor in
                let result = await attempt.value
                deadlineTask.cancel()
                guard !once.fired else { return }
                once.fired = true
                continuation.resume(returning: result)
            }
            Task { @MainActor in
                try? await deadlineTask.value
                guard !once.fired else { return }
                once.fired = true
                continuation.resume(returning: false)
            }
        }
    }

    // MARK: - Attempt lifecycle

    private func startAttempt() -> Task<Bool, Never> {
        cancelActiveAttempt()
        nextAttemptID &+= 1
        let attemptID = nextAttemptID
        activeAttemptID = attemptID
        isSigningIn = true
        return Task { @MainActor [weak self] in
            guard let self else { return false }
            defer { self.finishAttempt(attemptID) }
            guard self.activeAttemptID == attemptID else { return false }
            guard let callbackURL = await self.runBrowserSession(attemptID: attemptID) else {
                return self.coordinator.isAuthenticated
            }
            guard self.activeAttemptID == attemptID else { return false }
            return await self.completeCallback(url: callbackURL, attemptID: attemptID)
        }
    }

    private func runBrowserSession(attemptID: UInt64) async -> URL? {
        await withCheckedContinuation { continuation in
            let session = sessionFactory.makeSession(
                signInURL: makeSignInURL(),
                callbackScheme: callbackScheme()
            ) { url in
                // The factory delivers the completion exactly once (including
                // after cancel()), so this resume cannot double-fire.
                continuation.resume(returning: url)
            }
            guard session.start() else {
                log.log("auth.webauth: session.start() returned false")
                continuation.resume(returning: nil)
                return
            }
            guard activeAttemptID == attemptID else {
                session.cancel()
                return
            }
            activeSession = session
        }
    }

    private func finishAttempt(_ attemptID: UInt64) {
        guard activeAttemptID == attemptID else { return }
        activeAttemptID = nil
        activeSession = nil
        isSigningIn = false
    }

    private func cancelActiveAttempt() {
        activeAttemptID = nil
        activeSession?.cancel()
        activeSession = nil
        isSigningIn = false
    }

    // MARK: - Callback completion

    /// Seed the callback tokens and publish the session through the shared
    /// coordinator, guarding against a sign-out racing the round trip.
    private func completeCallback(url: URL, attemptID: UInt64?) async -> Bool {
        guard let payload = callbackRouter.callbackPayload(from: url) else {
            log.log("auth.callback rejected: invalid payload")
            return false
        }
        let generation = signOutGeneration
        await tokenStore.seed(accessToken: payload.accessToken, refreshToken: payload.refreshToken)
        guard signOutGeneration == generation,
              attemptID == nil || activeAttemptID == attemptID else {
            // A sign-out (or a newer attempt) raced the callback; drop the
            // seeded tokens instead of resurrecting the session.
            await tokenStore.clearTokensIfCurrent(
                accessToken: payload.accessToken,
                refreshToken: payload.refreshToken
            )
            return false
        }
        do {
            try await coordinator.completeExternalSignIn()
        } catch {
            log.log("auth.callback completion failed: \(error)")
            return false
        }
        guard signOutGeneration == generation else {
            // Sign-out ran while the validation round trip was in flight. The
            // user's intent wins: tear the just-published session back down.
            await coordinator.signOut()
            await tokenStore.clearTokensIfCurrent(
                accessToken: payload.accessToken,
                refreshToken: payload.refreshToken
            )
            return false
        }
        return true
    }
}

/// MainActor-confined once-guard for racing continuation resumes.
@MainActor
private final class ResumeOnceFlag {
    var fired = false
}
