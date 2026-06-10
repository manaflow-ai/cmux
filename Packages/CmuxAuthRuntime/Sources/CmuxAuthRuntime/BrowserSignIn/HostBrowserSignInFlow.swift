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
    private let makeSignInURL: @MainActor (_ callbackState: String) -> URL
    private let callbackScheme: @MainActor () -> String
    private let clock: any Clock<Duration>
    private let browserAttemptTimeout: TimeInterval
    private let log = AuthDebugLog()

    @ObservationIgnored private var activeSession: (any HostBrowserAuthSession)?
    @ObservationIgnored private var activeSessionContinuation: CheckedContinuation<URL?, Never>?
    @ObservationIgnored private var activeSessionContinuationAttemptID: UInt64?
    @ObservationIgnored private var activeAttemptTimeoutTask: Task<Void, Never>?
    @ObservationIgnored private var nextAttemptID: UInt64 = 0
    @ObservationIgnored private var activeAttemptID: UInt64?
    @ObservationIgnored private var activeCallbackState: String?
    @ObservationIgnored private var pendingManualCallbackState: String?
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
    ///   - browserAttemptTimeout: Cancels abandoned external-browser attempts.
    public init(
        coordinator: AuthCoordinator,
        tokenStore: any StackAuthTokenStoreProtocol,
        sessionFactory: any HostBrowserAuthSessionFactory,
        callbackRouter: AuthCallbackRouter,
        makeSignInURL: @escaping @MainActor (_ callbackState: String) -> URL,
        callbackScheme: @escaping @MainActor () -> String,
        clock: any Clock<Duration> = ContinuousClock(),
        browserAttemptTimeout: TimeInterval = 10 * 60
    ) {
        self.coordinator = coordinator
        self.tokenStore = tokenStore
        self.sessionFactory = sessionFactory
        self.callbackRouter = callbackRouter
        self.makeSignInURL = makeSignInURL
        self.callbackScheme = callbackScheme
        self.clock = clock
        self.browserAttemptTimeout = browserAttemptTimeout
    }

    /// Start a browser sign-in without awaiting the result (Settings button).
    /// Cancels any previous attempt's popup first.
    public func beginSignIn() {
        log.log("auth.browser.beginSignIn signedIn=\(coordinator.isAuthenticated) signingIn=\(isSigningIn)")
        _ = startAttempt()
    }

    /// The hosted sign-in URL for manual fallback when the browser handoff does
    /// not return to the native app.
    public var manualSignInURL: URL {
        let state = makeCallbackState()
        pendingManualCallbackState = state
        return makeSignInURL(state)
    }

    /// Run a browser sign-in attempt with a deadline, for the socket
    /// `auth.begin_sign_in` command. Returns whether the app ended signed in
    /// before the deadline; the popup itself stays up past the deadline so the
    /// user can still finish.
    public func signIn(timeout: TimeInterval) async -> Bool {
        log.log("auth.browser.signIn.request timeoutMs=\(Int(timeout * 1000)) signedIn=\(coordinator.isAuthenticated) signingIn=\(isSigningIn)")
        if coordinator.isAuthenticated {
            log.log("auth.browser.signIn.result result=alreadySignedIn")
            return true
        }
        let result = await awaitWithDeadline(startAttempt(), timeout: timeout)
        log.log("auth.browser.signIn.result signedIn=\(result)")
        return result
    }

    /// Handle an auth callback URL delivered through the app's URL scheme
    /// (e.g. the hosted page redirected in the user's real browser instead of
    /// the popup). Returns whether the app ended signed in.
    @discardableResult
    public func handleCallbackURL(_ url: URL) async -> Bool {
        log.log("auth.callback.external.received \(authCallbackSummary(url))")
        if let attemptID = activeAttemptID,
           activeSessionContinuation != nil,
           callbackRouter.isAuthCallbackURL(url) {
            guard callbackState(from: url) == activeCallbackState else {
                log.log("auth.callback.external.reject reason=stateMismatch attempt=\(attemptID)")
                return false
            }
            log.log("auth.callback.external.routeToActive attempt=\(attemptID)")
            cancelAttemptTimeout()
            let signedIn = await completeCallback(url: url, attemptID: attemptID)
            resumeActiveSessionContinuation(
                returning: nil,
                reason: "externalCallback",
                expectedAttemptID: attemptID
            )
            return signedIn
        }
        if callbackRouter.isAuthCallbackURL(url), callbackState(from: url) == nil {
            log.log("auth.callback.external.routeToFallback")
            return await completeCallback(url: url, attemptID: nil)
        }
        log.log("auth.callback.external.reject reason=noActiveAttempt")
        return false
    }

    /// Sign out, cancelling any in-flight browser attempt so a late callback
    /// can't resurrect the session.
    public func signOut() async {
        log.log("auth.browser.signOut.begin signingIn=\(isSigningIn) activeAttempt=\(activeAttemptID.map(String.init) ?? "nil") generation=\(signOutGeneration)")
        signOutGeneration &+= 1
        cancelActiveAttempt()
        await coordinator.signOut()
        log.log("auth.browser.signOut.end generation=\(signOutGeneration)")
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
        if let activeAttemptID {
            log.log("auth.browser.attempt.replace previous=\(activeAttemptID)")
        }
        cancelActiveAttempt()
        nextAttemptID &+= 1
        let attemptID = nextAttemptID
        let callbackState = pendingManualCallbackState ?? makeCallbackState()
        pendingManualCallbackState = nil
        activeAttemptID = attemptID
        activeCallbackState = callbackState
        isSigningIn = true
        log.log("auth.browser.attempt.start id=\(attemptID) generation=\(signOutGeneration) state=\(redactedState(callbackState))")
        scheduleAttemptTimeout(attemptID)
        return Task { @MainActor [weak self] in
            guard let self else { return false }
            defer { self.finishAttempt(attemptID) }
            guard self.activeAttemptID == attemptID else { return false }
            guard let callbackURL = await self.runBrowserSession(attemptID: attemptID) else {
                self.log.log("auth.browser.attempt.noCallback id=\(attemptID) signedIn=\(self.coordinator.isAuthenticated)")
                return self.coordinator.isAuthenticated
            }
            guard self.activeAttemptID == attemptID else { return false }
            self.cancelAttemptTimeout()
            return await self.completeCallback(url: callbackURL, attemptID: attemptID)
        }
    }

    private func runBrowserSession(attemptID: UInt64) async -> URL? {
        await withCheckedContinuation { continuation in
            activeSessionContinuation = continuation
            activeSessionContinuationAttemptID = attemptID
            let callbackState = activeCallbackState ?? makeCallbackState()
            let signInURL = makeSignInURL(callbackState)
            let scheme = callbackScheme()
            log.log("auth.browser.session.create id=\(attemptID) signInURL=\(signInURL.absoluteString) callbackScheme=\(scheme)")
            let session = sessionFactory.makeSession(
                signInURL: signInURL,
                callbackScheme: scheme
            ) { url in
                // The factory delivers the completion exactly once (including
                // after cancel()), so this resume cannot double-fire.
                self.log.log("auth.browser.session.completion id=\(attemptID) \(url.map(authCallbackSummary) ?? "url=nil")")
                if let url, !self.callbackRouter.isAuthCallbackURL(url) {
                    self.log.log("auth.browser.session.completion.ignored id=\(attemptID) reason=nonAuthCallback \(authCallbackSummary(url))")
                    return
                }
                self.resumeActiveSessionContinuation(
                    returning: url,
                    reason: "sessionCompletion",
                    expectedAttemptID: attemptID
                )
            }
            let started = session.start()
            log.log("auth.browser.session.start id=\(attemptID) started=\(started)")
            guard started else {
                log.log("auth.webauth: session.start() returned false")
                resumeActiveSessionContinuation(
                    returning: nil,
                    reason: "startFailed",
                    expectedAttemptID: attemptID
                )
                return
            }
            guard activeAttemptID == attemptID else {
                log.log("auth.browser.session.cancel id=\(attemptID) reason=staleAfterStart active=\(activeAttemptID.map(String.init) ?? "nil")")
                session.cancel()
                return
            }
            activeSession = session
        }
    }

    private func finishAttempt(_ attemptID: UInt64) {
        guard activeAttemptID == attemptID else { return }
        log.log("auth.browser.attempt.finish id=\(attemptID)")
        resumeActiveSessionContinuation(
            returning: nil,
            reason: "finishAttempt",
            expectedAttemptID: attemptID
        )
        cancelAttemptTimeout()
        activeAttemptID = nil
        activeCallbackState = nil
        activeSession = nil
        isSigningIn = false
    }

    private func cancelActiveAttempt() {
        if let activeAttemptID {
            log.log("auth.browser.attempt.cancel id=\(activeAttemptID)")
        }
        resumeActiveSessionContinuation(returning: nil, reason: "cancelAttempt")
        cancelAttemptTimeout()
        activeAttemptID = nil
        activeCallbackState = nil
        activeSession?.cancel()
        activeSession = nil
        isSigningIn = false
    }

    private func scheduleAttemptTimeout(_ attemptID: UInt64) {
        activeAttemptTimeoutTask?.cancel()
        guard browserAttemptTimeout > 0 else {
            activeAttemptTimeoutTask = nil
            return
        }
        let timeout = browserAttemptTimeout
        let clock = self.clock
        activeAttemptTimeoutTask = Task { @MainActor [weak self] in
            try? await clock.sleep(for: .seconds(timeout))
            guard !Task.isCancelled, let self, self.activeAttemptID == attemptID else { return }
            self.log.log("auth.browser.attempt.timeout id=\(attemptID)")
            self.cancelActiveAttempt()
        }
    }

    private func cancelAttemptTimeout() {
        activeAttemptTimeoutTask?.cancel()
        activeAttemptTimeoutTask = nil
    }

    // MARK: - Callback completion

    /// Seed the callback tokens and publish the session through the shared
    /// coordinator, guarding against a sign-out racing the round trip.
    private func completeCallback(url: URL, attemptID: UInt64?) async -> Bool {
        log.log("auth.callback.complete.begin attempt=\(attemptID.map(String.init) ?? "external") \(authCallbackSummary(url))")
        guard let payload = callbackRouter.callbackPayload(from: url) else {
            log.log("auth.callback rejected: invalid payload")
            return false
        }
        if let attemptID {
            guard callbackState(from: url) == activeCallbackState else {
                log.log("auth.callback rejected: state mismatch attempt=\(attemptID)")
                return false
            }
        } else if callbackState(from: url) != nil {
            log.log("auth.callback rejected: stateful external callback without active attempt")
            return false
        }
        let generation = signOutGeneration
        log.log("auth.callback.tokens.seed attempt=\(attemptID.map(String.init) ?? "external") generation=\(generation)")
        await tokenStore.seed(accessToken: payload.accessToken, refreshToken: payload.refreshToken)
        guard signOutGeneration == generation,
              attemptID == nil || activeAttemptID == attemptID else {
            // A sign-out (or a newer attempt) raced the callback; drop the
            // seeded tokens instead of resurrecting the session.
            log.log("auth.callback.tokens.clear attempt=\(attemptID.map(String.init) ?? "external") reason=raced generation=\(signOutGeneration) active=\(activeAttemptID.map(String.init) ?? "nil")")
            await tokenStore.clearTokensIfCurrent(
                accessToken: payload.accessToken,
                refreshToken: payload.refreshToken
            )
            return false
        }
        do {
            log.log("auth.callback.coordinator.complete.begin attempt=\(attemptID.map(String.init) ?? "external")")
            try await coordinator.completeExternalSignIn()
        } catch {
            log.log("auth.callback completion failed: \(error)")
            if signOutGeneration != generation {
                // A sign-out raced the validation round trip and the
                // coordinator dropped the publish (its session-generation
                // guard surfaces cancellation); drop the seeded tokens too so
                // the dead callback credentials don't linger in the store.
                await tokenStore.clearTokensIfCurrent(
                    accessToken: payload.accessToken,
                    refreshToken: payload.refreshToken
                )
            }
            return false
        }
        log.log("auth.callback.coordinator.complete.end attempt=\(attemptID.map(String.init) ?? "external") signedIn=\(coordinator.isAuthenticated)")
        guard signOutGeneration == generation else {
            // Sign-out ran while the validation round trip was in flight. The
            // user's intent wins: tear the just-published session back down.
            log.log("auth.callback.coordinator.rollback attempt=\(attemptID.map(String.init) ?? "external") reason=signOutRaced generation=\(signOutGeneration)")
            await coordinator.signOut()
            await tokenStore.clearTokensIfCurrent(
                accessToken: payload.accessToken,
                refreshToken: payload.refreshToken
            )
            return false
        }
        return true
    }

    private func resumeActiveSessionContinuation(
        returning url: URL?,
        reason: String,
        expectedAttemptID: UInt64? = nil
    ) {
        guard let continuation = activeSessionContinuation else { return }
        if let expectedAttemptID,
           activeSessionContinuationAttemptID != expectedAttemptID {
            log.log("auth.browser.session.resume.ignore reason=\(reason) expected=\(expectedAttemptID) active=\(activeSessionContinuationAttemptID.map(String.init) ?? "nil")")
            return
        }
        activeSessionContinuation = nil
        activeSessionContinuationAttemptID = nil
        log.log("auth.browser.session.resume reason=\(reason) \(url.map(authCallbackSummary) ?? "url=nil")")
        continuation.resume(returning: url)
    }

    private func makeCallbackState() -> String {
        UUID().uuidString.lowercased()
    }

    private func callbackState(from url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "cmux_auth_state" })?
            .value
    }

    private func redactedState(_ state: String) -> String {
        "\(state.prefix(8))..."
    }
}

/// MainActor-confined once-guard for racing continuation resumes.
@MainActor
private final class ResumeOnceFlag {
    var fired = false
}

private func authCallbackSummary(_ url: URL) -> String {
    let scheme = url.scheme ?? "nil"
    let target = url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?
        .queryItems?
        .map(\.name)
        .joined(separator: ",") ?? ""
    return "scheme=\(scheme) target=\(target.isEmpty ? "nil" : target) queryKeys=\(queryItems.isEmpty ? "none" : queryItems)"
}
