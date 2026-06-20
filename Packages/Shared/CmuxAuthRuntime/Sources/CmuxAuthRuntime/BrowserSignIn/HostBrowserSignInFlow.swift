public import Foundation
public import Observation
import os

/// macOS hosted-browser sign-in flow, including external URL callbacks and
/// attempt/sign-out race guards.
@MainActor
@Observable
public final class HostBrowserSignInFlow {
    /// Whether a browser sign-in attempt (popup + completion) is in flight.
    public private(set) var isSigningIn = false

    /// Whether the in-flight popup has waited long enough for the UI to offer
    /// the default-browser fallback instead of an indefinite spinner.
    public private(set) var signInIsSlow = false

    /// Display-safe failure from the most recent hosted-browser sign-in
    /// attempt. `nil` for a fresh attempt and for deliberate cancellation.
    public private(set) var lastFailure: AuthError?

    private let coordinator: AuthCoordinator
    private let tokenStore: any StackAuthTokenStoreProtocol
    private let sessionFactory: any HostBrowserAuthSessionFactory
    private let callbackRouter: AuthCallbackRouter
    private let makeSignInURL: @MainActor (_ callbackState: String) -> URL
    private let callbackScheme: @MainActor () -> String
    private let clock: any Clock<Duration>
    private let browserAttemptTimeout: TimeInterval
    private let slowSignInThreshold: TimeInterval
    private let log = AuthDebugLog()

    @ObservationIgnored private var activeSession: (any HostBrowserAuthSession)?
    @ObservationIgnored private var activeSessionContinuation: CheckedContinuation<URL?, Never>?
    @ObservationIgnored private var activeSessionContinuationAttemptID: UInt64?
    @ObservationIgnored private var activeAttemptTimeoutTask: Task<Void, Never>?
    @ObservationIgnored private var slowSignInHintTask: Task<Void, Never>?
    @ObservationIgnored private var nextAttemptID: UInt64 = 0
    @ObservationIgnored private var activeAttemptID: UInt64?
    @ObservationIgnored private var activeCallbackState: String?
    @ObservationIgnored private var pendingManualCallbackState: String?
    @ObservationIgnored private var pendingFallbackCallbackState: String?
    @ObservationIgnored private var signOutGeneration: UInt64 = 0

    /// Creates the flow.
    public init(
        coordinator: AuthCoordinator,
        tokenStore: any StackAuthTokenStoreProtocol,
        sessionFactory: any HostBrowserAuthSessionFactory,
        callbackRouter: AuthCallbackRouter,
        makeSignInURL: @escaping @MainActor (_ callbackState: String) -> URL,
        callbackScheme: @escaping @MainActor () -> String,
        clock: any Clock<Duration> = ContinuousClock(),
        browserAttemptTimeout: TimeInterval = 10 * 60,
        slowSignInThreshold: TimeInterval = 30
    ) {
        self.coordinator = coordinator
        self.tokenStore = tokenStore
        self.sessionFactory = sessionFactory
        self.callbackRouter = callbackRouter
        self.makeSignInURL = makeSignInURL
        self.callbackScheme = callbackScheme
        self.clock = clock
        self.browserAttemptTimeout = browserAttemptTimeout
        self.slowSignInThreshold = slowSignInThreshold
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

    /// Sign-in URL for the active attempt, reused by the default-browser fallback
    /// so the callback still routes to this in-flight attempt.
    public var activeAttemptSignInURL: URL? {
        guard let activeCallbackState else { return nil }
        pendingFallbackCallbackState = activeCallbackState
        return makeSignInURL(activeCallbackState)
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
            guard authCallbackState(from: url) == activeCallbackState else {
                log.log("auth.callback.external.reject reason=stateMismatch attempt=\(attemptID)")
                lastFailure = .invalidCallback
                return false
            }
            log.log("auth.callback.external.routeToActive attempt=\(attemptID)")
            cancelAttemptTimeout()
            cancelSlowSignInHint()
            let signedIn = await completeCallback(url: url, attemptID: attemptID)
            resumeActiveSessionContinuation(
                returning: nil,
                reason: "externalCallback",
                expectedAttemptID: attemptID
            )
            return signedIn
        }
        if callbackRouter.isAuthCallbackURL(url), authCallbackState(from: url) == nil {
            log.log("auth.callback.external.routeToFallback")
            return await completeCallback(url: url, attemptID: nil)
        }
        if callbackRouter.isAuthCallbackURL(url),
           let state = authCallbackState(from: url),
           state == pendingFallbackCallbackState {
            log.log("auth.callback.external.routeToIssuedFallback")
            return await completeCallback(url: url, attemptID: nil, acceptedExternalState: state)
        }
        log.log("auth.callback.external.reject reason=noActiveAttempt")
        return false
    }

    /// Sign out, cancelling any in-flight browser attempt so a late callback
    /// can't resurrect the session.
    public func signOut() async {
        log.log("auth.browser.signOut.begin signingIn=\(isSigningIn) activeAttempt=\(activeAttemptID.map(String.init) ?? "nil") generation=\(signOutGeneration)")
        signOutGeneration &+= 1
        lastFailure = nil
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

    /// Await `attempt`, resolving `false` at the deadline while the underlying
    /// attempt keeps running in the background.
    private func awaitWithDeadline(_ attempt: Task<Bool, Never>, timeout: TimeInterval) async -> Bool {
        // Clamp before converting so an oversized Double can't overflow.
        let clamped = max(0, min(timeout, 24 * 60 * 60))
        let clock = self.clock
        let stream = AsyncStream<Bool>(bufferingPolicy: .bufferingOldest(1)) { continuation in
            let deadlineTask = Task {
                do {
                    try await clock.sleep(for: .seconds(clamped))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                continuation.yield(false)
                continuation.finish()
            }
            let attemptWaitTask = Task {
                let result = await attempt.value
                continuation.yield(result)
                continuation.finish()
                deadlineTask.cancel()
            }
            continuation.onTermination = { @Sendable _ in
                deadlineTask.cancel()
                attemptWaitTask.cancel()
            }
        }
        for await result in stream {
            return result
        }
        return false
    }

    // MARK: - Attempt lifecycle

    private func startAttempt() -> Task<Bool, Never> {
        if let activeAttemptID {
            log.log("auth.browser.attempt.replace previous=\(activeAttemptID)")
        }
        cancelActiveAttempt()
        lastFailure = nil
        nextAttemptID &+= 1
        let attemptID = nextAttemptID
        let callbackState = pendingManualCallbackState ?? makeCallbackState()
        pendingManualCallbackState = nil
        activeAttemptID = attemptID
        activeCallbackState = callbackState
        isSigningIn = true
        log.log("auth.browser.attempt.start id=\(attemptID) generation=\(signOutGeneration) state=\(redactedAuthState(callbackState))")
        scheduleAttemptTimeout(attemptID)
        scheduleSlowSignInHint(attemptID)
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
            self.cancelSlowSignInHint()
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
                self.log.log("auth.browser.session.completion id=\(attemptID) \(url.map(self.authCallbackSummary) ?? "url=nil")")
                if let url, !self.callbackRouter.isAuthCallbackURL(url) {
                    self.log.log("auth.browser.session.completion.ignored id=\(attemptID) reason=nonAuthCallback \(self.authCallbackSummary(url))")
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
        cancelSlowSignInHint()
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
        cancelSlowSignInHint()
        activeAttemptID = nil
        activeCallbackState = nil
        pendingFallbackCallbackState = nil
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
            self.lastFailure = .timedOut
            self.cancelActiveAttempt()
        }
    }

    private func cancelAttemptTimeout() {
        activeAttemptTimeoutTask?.cancel()
        activeAttemptTimeoutTask = nil
    }

    /// After ``slowSignInThreshold`` of an attempt still waiting on the hosted
    /// browser, flip ``signInIsSlow`` so the account UI can offer the manual
    /// default-browser fallback. Non-destructive: the popup keeps running, so a
    /// user who is simply taking their time can still finish in it.
    private func scheduleSlowSignInHint(_ attemptID: UInt64) {
        slowSignInHintTask?.cancel()
        guard slowSignInThreshold > 0 else {
            slowSignInHintTask = nil
            return
        }
        let threshold = slowSignInThreshold
        let clock = self.clock
        slowSignInHintTask = Task { @MainActor [weak self] in
            try? await clock.sleep(for: .seconds(threshold))
            guard !Task.isCancelled, let self, self.activeAttemptID == attemptID else { return }
            self.log.log("auth.browser.attempt.slow id=\(attemptID)")
            self.signInIsSlow = true
        }
    }

    private func cancelSlowSignInHint() {
        slowSignInHintTask?.cancel()
        slowSignInHintTask = nil
        signInIsSlow = false
    }

    // MARK: - Callback completion

    /// Seed the callback tokens and publish the session through the shared
    /// coordinator, guarding against a sign-out racing the round trip.
    private func completeCallback(url: URL, attemptID: UInt64?, acceptedExternalState: String? = nil) async -> Bool {
        log.log("auth.callback.complete.begin attempt=\(attemptID.map(String.init) ?? "external") \(authCallbackSummary(url))")
        guard let payload = callbackRouter.callbackPayload(from: url) else {
            log.log("auth.callback rejected: invalid payload")
            lastFailure = .invalidCallback
            return false
        }
        if let attemptID {
            guard authCallbackState(from: url) == activeCallbackState else {
                log.log("auth.callback rejected: state mismatch attempt=\(attemptID)")
                lastFailure = .invalidCallback
                return false
            }
        } else if let state = authCallbackState(from: url), state != acceptedExternalState {
            log.log("auth.callback rejected: stateful external callback without active attempt")
            lastFailure = .invalidCallback
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
            let displaySafe = AuthError(displaySafe: error) ?? .serverError(0, "auth_failed")
            if displaySafe != .cancelled {
                lastFailure = displaySafe
            }
            // No flow-side seed clear here, deliberately. When a sign-out
            // raced the validation round trip, the seeds were already in the
            // store when the coordinator's local-first clear ran (they are
            // seeded before `completeExternalSignIn`), so the coordinator's
            // clear owns wiping them. Clearing here instead RACES that
            // sign-out: the flow bumps `signOutGeneration` before the
            // coordinator captures the teardown credentials with raw store
            // reads, so a clear from this catch can empty the store inside
            // the capture window and silently strip the best-effort server
            // teardown (push unregister, session revocation) of its
            // credentials. A coordinator-level cancellation without a
            // sign-out (a concurrent publish) must not clear either: in
            // production the published session is typically authenticated by
            // these very tokens (same shared store), and clearing them would
            // strand it.
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
        if authCallbackState(from: url) == pendingFallbackCallbackState {
            pendingFallbackCallbackState = nil
        }
        lastFailure = nil
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

    private func authCallbackState(from url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "cmux_auth_state" })?
            .value
    }

    private func redactedAuthState(_ state: String) -> String {
        "\(state.prefix(8))..."
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

}
