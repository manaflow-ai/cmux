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
    @ObservationIgnored private var activeSessionContinuation: CheckedContinuation<HostBrowserAuthSessionResult?, Never>?
    @ObservationIgnored private var activeSessionContinuationAttemptID: UInt64?
    @ObservationIgnored private var activeAttemptTimeoutTask: Task<Void, Never>?
    @ObservationIgnored private var slowSignInHintTask: Task<Void, Never>?
    @ObservationIgnored private var nextAttemptID: UInt64 = 0
    @ObservationIgnored private var activeAttemptID: UInt64?
    @ObservationIgnored private var activeCallbackState: String?
    @ObservationIgnored private var pendingManualCallbackState: String?
    @ObservationIgnored private var pendingFallbackCallbackState: String?
    /// Callback state for a default-browser recovery the user opened from the
    /// signed-out error state. Unlike ``pendingFallbackCallbackState`` it is
    /// owned by an already-opened browser, not by an in-flight popup attempt,
    /// so popup teardown (``cancelActiveAttempt()`` / ``startAttempt()``) must
    /// not clear it — only completion and sign-out do (issue #6015).
    @ObservationIgnored private var pendingDefaultBrowserCallbackState: String?
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

    /// Sign-in URL for completing sign-in entirely in the user's default
    /// browser when no popup attempt is in flight — e.g. the Safari-backed
    /// `ASWebAuthenticationSession` popup already failed or was dismissed and
    /// the account UI is offering the recovery affordance from a signed-out
    /// error state (issue #6015). Records the issued callback state so the
    /// `cmux://auth-callback` deep link routes back through
    /// ``handleCallbackURL(_:)`` and finishes the sign-in even though no
    /// attempt is active — the no-active-attempt mirror of
    /// ``activeAttemptSignInURL``.
    public var defaultBrowserSignInURL: URL {
        // Reuse an outstanding issued state so repeated taps — a common "nothing
        // happened, click again" reaction to a hung popup — keep routing to the
        // same callback instead of orphaning the earlier browser tab. The state
        // lives in its own durable slot (not ``pendingFallbackCallbackState``)
        // so that also clicking "Sign In…" — which starts a popup attempt and
        // clears the popup-scoped slot — does not invalidate the browser the
        // user actually completes. Cleared on completion and sign-out, so a
        // later recovery still gets a fresh state.
        let state = pendingDefaultBrowserCallbackState ?? makeCallbackState()
        pendingDefaultBrowserCallbackState = state
        return makeSignInURL(state)
    }

    /// Run a browser sign-in attempt with a deadline for `auth.begin_sign_in`.
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
        // A durable default-browser recovery callback wins even when a fresh
        // popup attempt is now active: the user opened that browser tab from the
        // error state and may have also clicked "Sign In…". Match its state
        // explicitly, ahead of the active-attempt check below, so the browser
        // the user actually finished in is not rejected as a state mismatch
        // (issue #6015).
        if callbackRouter.isAuthCallbackURL(url),
           let state = authCallbackState(from: url),
           state == pendingDefaultBrowserCallbackState {
            log.log("auth.callback.external.routeToDefaultBrowser activeAttempt=\(activeAttemptID.map(String.init) ?? "nil")")
            let signedIn = await completeCallback(url: url, attemptID: nil, acceptedExternalState: state)
            if signedIn, let attemptID = activeAttemptID {
                // Tear down the orphaned popup the user also started so its
                // Safari window closes once the browser tab completed sign-in.
                // Only on success — a recovery callback that fails to validate
                // must leave the user's still-viable popup attempt (and its
                // timeout / slow-sign-in hint) intact.
                cancelAttemptTimeout()
                cancelSlowSignInHint()
                resumeActiveSessionContinuation(
                    returning: .cancelled(reason: "external_callback"),
                    reason: "externalDefaultBrowserCallback",
                    expectedAttemptID: attemptID
                )
            }
            return signedIn
        }
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
                returning: .cancelled(reason: "external_callback"),
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
        // cancelActiveAttempt() clears the popup-scoped fallback slot; the
        // durable default-browser slot is user-scoped, so sign-out invalidates
        // it explicitly here.
        pendingDefaultBrowserCallbackState = nil
        cancelActiveAttempt()
        await coordinator.signOut()
        log.log("auth.browser.signOut.end generation=\(signOutGeneration)")
    }

    /// Sign out with a socket deadline while sign-out continues in background.
    public func signOut(timeout: TimeInterval) async {
        // Strong capture keeps user-requested sign-out alive past caller timeout.
        let attempt = Task { @MainActor in
            await self.signOut()
            return true
        }
        _ = await awaitWithDeadline(attempt, timeout: timeout)
    }

    /// Await `attempt`, resolving `false` at the deadline without cancelling it.
    private func awaitWithDeadline(_ attempt: Task<Bool, Never>, timeout: TimeInterval) async -> Bool {
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
            guard let result = await self.runBrowserSession(attemptID: attemptID) else {
                self.log.log("auth.browser.attempt.noResult id=\(attemptID) signedIn=\(self.coordinator.isAuthenticated)")
                return self.coordinator.isAuthenticated
            }
            switch result {
            case let .callback(callbackURL):
                guard self.activeAttemptID == attemptID else { return false }
                self.cancelAttemptTimeout()
                self.cancelSlowSignInHint()
                return await self.completeCallback(url: callbackURL, attemptID: attemptID)
            case let .cancelled(reason):
                self.log.log("auth.browser.attempt.cancelled id=\(attemptID) reason=\(reason) signedIn=\(self.coordinator.isAuthenticated)")
                if self.activeAttemptID == attemptID,
                   self.signInIsSlow,
                   !self.coordinator.isAuthenticated {
                    // Issue #6015: the user dismissed an ASWebAuthenticationSession
                    // popup that had already hung past the slow threshold without
                    // ever redirecting back to cmux://auth-callback. Record an
                    // actionable failure so the account UI surfaces guidance and
                    // keeps the default-browser fallback reachable instead of
                    // silently dropping back to "Not signed in". This only fires
                    // for a genuine user dismissal of the still-active popup —
                    // sign-out / replace clear activeAttemptID before resuming, so
                    // our own teardown never lands here.
                    self.recordBrowserSessionFailure(reason: "dismissed_after_slow", attemptID: attemptID)
                }
                return self.coordinator.isAuthenticated
            case let .failed(reason):
                self.recordBrowserSessionFailure(reason: reason, attemptID: attemptID)
                return self.coordinator.isAuthenticated
            }
        }
    }

    private func runBrowserSession(attemptID: UInt64) async -> HostBrowserAuthSessionResult? {
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
            ) { result in
                self.log.log("auth.browser.session.completion id=\(attemptID) \(self.sessionResultSummary(result))")
                if case let .callback(url) = result, !self.callbackRouter.isAuthCallbackURL(url) {
                    self.log.log("auth.browser.session.completion.ignored id=\(attemptID) reason=nonAuthCallback \(self.authCallbackSummary(url))")
                    return
                }
                self.resumeActiveSessionContinuation(
                    returning: result,
                    reason: "sessionCompletion",
                    expectedAttemptID: attemptID
                )
            }
            let started = session.start()
            log.log("auth.browser.session.start id=\(attemptID) started=\(started)")
            guard started else {
                log.log("auth.webauth: session.start() returned false")
                resumeActiveSessionContinuation(
                    returning: .failed(reason: "start_returned_false"),
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
            returning: .cancelled(reason: "finish_attempt"),
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
        resumeActiveSessionContinuation(
            returning: .cancelled(reason: "attempt_cancelled"),
            reason: "cancelAttempt"
        )
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

    /// Flip on the non-destructive default-browser fallback after a slow popup.
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

    private func recordBrowserSessionFailure(reason: String, attemptID: UInt64) {
        log.log("auth.browser.attempt.failed id=\(attemptID) reason=\(reason) signedIn=\(coordinator.isAuthenticated)")
        if !coordinator.isAuthenticated {
            lastFailure = .browserSignInFailed(reason)
        }
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
            // Drop raced tokens instead of resurrecting a signed-out/replaced session.
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
            guard signOutGeneration == generation,
                  attemptID == nil || activeAttemptID == attemptID
            else {
                return false
            }
            let displaySafe = AuthError(displaySafe: error) ?? .serverError(0, "auth_failed")
            if displaySafe != .cancelled {
                lastFailure = displaySafe
            }
            // Do not clear seeds here. The coordinator owns raced sign-out
            // teardown credentials and concurrent publish cancellation.
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
        // A successful sign-in via ANY path makes a lingering default-browser
        // recovery state moot — clear it unconditionally so an abandoned
        // recovery tab can't later re-seed tokens and replace the live session.
        pendingDefaultBrowserCallbackState = nil
        lastFailure = nil
        return true
    }

    private func resumeActiveSessionContinuation(
        returning result: HostBrowserAuthSessionResult?,
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
        log.log("auth.browser.session.resume reason=\(reason) \(result.map(sessionResultSummary) ?? "result=nil")")
        continuation.resume(returning: result)
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

    private func sessionResultSummary(_ result: HostBrowserAuthSessionResult) -> String {
        switch result {
        case let .callback(url):
            return "result=callback \(authCallbackSummary(url))"
        case let .cancelled(reason):
            return "result=cancelled reason=\(reason)"
        case let .failed(reason):
            return "result=failed reason=\(reason)"
        }
    }

}
