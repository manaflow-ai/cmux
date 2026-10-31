public import Foundation
public import Observation
import os
import StackAuth

/// macOS hosted-browser sign-in flow, including external URL callbacks and
/// attempt/sign-out race guards.
@MainActor
@Observable
public final class HostBrowserSignInFlow {
    /// Whether a browser sign-in attempt (popup + completion) is in flight.
    public private(set) var isSigningIn = false
    /// Whether sign-in progress should be visible and disable UI entrypoints.
    public private(set) var isPresentingSignIn = false
    /// Whether the UI should offer the default-browser fallback.
    public private(set) var signInIsSlow = false
    /// Display-safe failure from the most recent hosted-browser sign-in attempt.
    public private(set) var lastFailure: AuthError? {
        didSet { lastFailureDetail = lastFailure?.failureDetail }
    }
    /// One-line, token-free description of ``lastFailure`` (error code, HTTP
    /// status, provider request ID) that users can copy into a bug report.
    public private(set) var lastFailureDetail: String?
    /// Whether the callback completion is waiting to retry after the sign-in
    /// service answered 429. The UI shows a rate-limit message, not a failure.
    public private(set) var isRetryingAfterRateLimit = false

    private let coordinator: AuthCoordinator
    private let tokenStore: any StackAuthTokenStoreProtocol
    private let sessionFactory: any HostBrowserAuthSessionFactory
    private let callbackRouter: AuthCallbackRouter
    private let makeSignInURL: @MainActor (_ callbackState: String) -> URL
    private let callbackScheme: @MainActor () -> String
    /// Opens a URL in the user's default browser. Returns `true` when the
    /// launch was handed to a browser, `false` when it could not be opened.
    @ObservationIgnored private let openExternalURL: @MainActor (URL) -> Bool
    /// Asks the user whether an unsolicited, stateless callback may sign the
    /// app in. Defaults to denying every such callback.
    @ObservationIgnored private let approveUnsolicitedCallback: @MainActor (UnsolicitedAuthCallbackApprovalRequest) async -> Bool
    private let clock: any Clock<Duration>
    private let browserAttemptTimeout: TimeInterval
    /// How long a default-browser handoff waits for its callback before it ends as `browser_timeout`.
    private let browserHandoffTimeout: TimeInterval
    private let slowSignInThreshold: TimeInterval
    private let instantCancelWindow: TimeInterval
    private let signOutCoordinator: HostBrowserSignOutCoordinator
    private let callbackStateGenerator = HostBrowserCallbackStateGenerator()
    private let deadline: HostBrowserDeadline
    private let log = AuthDebugLog()

    @ObservationIgnored private var activeSession: (any HostBrowserAuthSession)?
    @ObservationIgnored private var activeSessionContinuation: CheckedContinuation<HostBrowserAuthSessionResult?, Never>?
    @ObservationIgnored private var activeSessionContinuationAttemptID: UInt64?
    @ObservationIgnored private var activeAttemptTimeoutTask: Task<Void, Never>?
    @ObservationIgnored private var activeAttemptTask: Task<Bool, Never>?
    @ObservationIgnored private var slowSignInHintTask: Task<Void, Never>?
    @ObservationIgnored private var nextAttemptID: UInt64 = 0
    @ObservationIgnored private var activeAttemptID: UInt64?
    @ObservationIgnored private var handedOffAttemptID: UInt64?
    /// Time since the active popup started, for telling a browser's instant
    /// cancel from the person's.
    @ObservationIgnored private var popupAge: (attemptID: UInt64, isFresh: @Sendable () -> Bool)?
    @ObservationIgnored private var activeCallbackState: String?
    @ObservationIgnored private var activeAttemptSelectsAccount = false
    @ObservationIgnored private var pendingManualCallbackState: String?
    /// App-issued states a callback may present after the popup ends.
    @ObservationIgnored private var issuedCallbackStates = HostBrowserIssuedCallbackStates()
    @ObservationIgnored private var isAwaitingCallbackApproval = false
    @ObservationIgnored private var signOutGeneration: UInt64 = 0
    /// `nextAttemptID` at the last sign-out: no attempt started since, so a late
    /// callback the sign-out made stale stays quiet instead of reporting a failure.
    @ObservationIgnored private var signedOutAtAttempt: UInt64?
    private var signedOutSinceLastAttempt: Bool { signedOutAtAttempt == nextAttemptID }
    /// The attempt whose callback is being completed: its tokens are already
    /// seeded, so a Cancel then is ignored rather than tearing it down mid-way.
    @ObservationIgnored private var completingAttemptID: UInt64?
    /// Pending waits before rate-limited completions retry, keyed by epoch.
    /// Sign-out and a replacing attempt cancel every one, so no stale wait
    /// lingers or retries beside the new attempt.
    @ObservationIgnored private var rateLimitWaits: [UInt64: Task<Void, Never>] = [:]
    /// Bumped per rate-limit wait and per cancellation, so a stale completion
    /// cannot clear ``isRetryingAfterRateLimit`` for a newer wait.
    @ObservationIgnored private var rateLimitEpoch: UInt64 = 0

    /// Creates the flow.
    public init(
        coordinator: AuthCoordinator,
        tokenStore: any StackAuthTokenStoreProtocol,
        sessionFactory: any HostBrowserAuthSessionFactory,
        callbackRouter: AuthCallbackRouter,
        makeSignInURL: @escaping @MainActor (_ callbackState: String) -> URL,
        callbackScheme: @escaping @MainActor () -> String,
        openExternalURL: @escaping @MainActor (URL) -> Bool,
        approveUnsolicitedCallback: @escaping @MainActor (UnsolicitedAuthCallbackApprovalRequest) async -> Bool = { _ in false },
        clock: any Clock<Duration> = ContinuousClock(),
        browserAttemptTimeout: TimeInterval = 10 * 60,
        browserHandoffTimeout: TimeInterval = 5 * 60,
        slowSignInThreshold: TimeInterval = 30,
        instantCancelWindow: TimeInterval = 1.5,
        beginSignOut: @escaping @MainActor @Sendable () -> Void = {},
        localSignOut: @escaping @MainActor @Sendable () async -> Void = {},
        onSignedOut: @escaping @Sendable (
            _ accessToken: String?,
            _ refreshToken: String?
        ) async -> Void = { _, _ in }
    ) {
        self.coordinator = coordinator
        self.tokenStore = tokenStore
        self.sessionFactory = sessionFactory
        self.callbackRouter = callbackRouter
        self.makeSignInURL = makeSignInURL
        self.callbackScheme = callbackScheme
        self.openExternalURL = openExternalURL
        self.approveUnsolicitedCallback = approveUnsolicitedCallback
        self.clock = clock
        self.browserAttemptTimeout = browserAttemptTimeout
        self.browserHandoffTimeout = browserHandoffTimeout
        self.slowSignInThreshold = slowSignInThreshold
        self.instantCancelWindow = instantCancelWindow
        deadline = HostBrowserDeadline(clock: clock)
        signOutCoordinator = HostBrowserSignOutCoordinator(
            beginSignOut: beginSignOut,
            localSignOut: localSignOut,
            signOut: { await coordinator.signOut(onSignedOut: onSignedOut) }
        )
    }

    /// Start a browser sign-in without awaiting the result (Settings button).
    /// Reuses a handed-off attempt; otherwise cancels the previous popup.
    /// - Parameter selectAccount: `true` (Switch Account) asks the hosted page
    ///   to confirm which account to use even when the browser is signed in.
    ///   It never reuses a handed-off attempt, whose page did not ask.
    /// - Parameter inDefaultBrowser: `true` skips the popup: the hosted page
    ///   opens in the default browser at once and the attempt waits for its
    ///   `<scheme>://auth-callback`, as after a handoff.
    @discardableResult
    public func beginSignIn(selectAccount: Bool = false, inDefaultBrowser: Bool = false) -> Task<Bool, Never> {
        log.log("auth.browser.beginSignIn signedIn=\(coordinator.isAuthenticated) signingIn=\(isSigningIn) selectAccount=\(selectAccount) defaultBrowser=\(inDefaultBrowser)")
        if !selectAccount,
           let activeAttemptID,
           handedOffAttemptID == activeAttemptID,
           let activeAttemptTask {
            isPresentingSignIn = true
            signInIsSlow = true
            return activeAttemptTask
        }
        return startAttempt(selectAccount: selectAccount, inDefaultBrowser: inDefaultBrowser)
    }

    /// Ends the sign-in in progress (the person's Cancel). A late callback
    /// carrying its state is then rejected. Once its callback has arrived,
    /// the sign-in finishes instead: the tokens already replaced the previous
    /// session, so undoing it would sign the person out of every account.
    public func cancelSignIn() {
        guard let activeAttemptID else { return }
        guard completingAttemptID != activeAttemptID else {
            log.log("auth.browser.cancelSignIn.ignored id=\(activeAttemptID) reason=callbackCompleting")
            return
        }
        log.log("auth.browser.cancelSignIn")
        cancelActiveAttempt()
    }

    /// The hosted sign-in URL for a manual fallback.
    public var manualSignInURL: URL {
        let state = callbackStateGenerator.make()
        pendingManualCallbackState = state
        return makeSignInURL(state)
    }

    /// Sign-in URL for the active attempt's default-browser fallback.
    public var activeAttemptSignInURL: URL? {
        guard let activeCallbackState else { return nil }
        issueCallbackState(activeCallbackState)
        return attemptSignInURL(activeCallbackState)
    }

    /// Run a browser sign-in attempt with a deadline for `auth.begin_sign_in`.
    public func signIn(timeout: TimeInterval) async -> Bool {
        log.log("auth.browser.signIn.request timeoutMs=\(Int(timeout * 1000)) signedIn=\(coordinator.isAuthenticated) signingIn=\(isSigningIn)")
        if coordinator.isAuthenticated {
            log.log("auth.browser.signIn.result result=alreadySignedIn")
            return true
        }
        let result = await deadline.resolve(startAttempt(), timeout: timeout)
        log.log("auth.browser.signIn.result signedIn=\(result)")
        return result
    }

    /// Handle an auth callback URL delivered outside the popup session (the
    /// app's URL scheme, or the embedded browser's after-sign-in handoff).
    /// Returns whether the app ended signed in.
    ///
    /// A token-bearing callback is applied only when it carries the live
    /// attempt's state or an app-issued, unexpired, single-use state; when it
    /// is a stateless handoff from the trusted embedded browser; or when the
    /// user explicitly approves an unsolicited stateless callback. Everything
    /// else is rejected.
    @discardableResult
    public func handleCallbackURL(
        _ url: URL,
        delivery: AuthCallbackDelivery = .external
    ) async -> Bool {
        log.log("auth.callback.external.received delivery=\(delivery) \(authCallbackSummary(url))")
        guard callbackRouter.isAuthCallbackURL(url) else {
            log.log("auth.callback.external.reject reason=notCallback")
            return false
        }
        let state = authCallbackState(from: url)
        if let attemptID = activeAttemptID, activeSessionContinuation != nil {
            guard HostBrowserIssuedCallbackStates.constantTimeEquals(state, activeCallbackState) else {
                log.log("auth.callback.external.reject reason=stateMismatch attempt=\(attemptID)")
                lastFailure = .invalidCallback
                return false
            }
            log.log("auth.callback.external.routeToActive attempt=\(attemptID)")
            cancelAttemptTimeout()
            cancelSlowSignInHint()
            // Hold the session continuation while the callback validates.
            // Safari can report the hosted session cancelled in that window;
            // resuming then would end the attempt and drop these tokens as
            // raced.
            let continuation = takeActiveSessionContinuation()
            let signedIn = await completeCallback(url: url, attemptID: attemptID)
            log.log("auth.browser.session.resume reason=externalCallback attempt=\(attemptID)")
            continuation?.resume(returning: .cancelled(reason: "external_callback"))
            return signedIn
        }
        if let state {
            // Validate the payload before consuming, so a malformed delivery
            // cannot burn the user's still-pending state.
            guard callbackRouter.callbackPayload(from: url) != nil else {
                log.log("auth.callback.external.reject reason=invalidPayload")
                if !signedOutSinceLastAttempt { lastFailure = .invalidCallback }
                return false
            }
            guard issuedCallbackStates.consume(state) else {
                log.log("auth.callback.external.reject reason=unknownOrExpiredState")
                // Relaunch loses issued states. Keep rejecting the callback, but
                // let the signed-out UI offer a fresh attempt instead of silence.
                // A sign-out since the last attempt cleared the states on purpose: stay quiet.
                guard !signedOutSinceLastAttempt else { return false }
                let generation = signOutGeneration
                let attempt = nextAttemptID
                await coordinator.awaitBootstrapped()
                if generation == signOutGeneration, attempt == nextAttemptID,
                   !isSigningIn, !coordinator.isAuthenticated { lastFailure = .invalidCallback }
                return false
            }
            log.log("auth.callback.external.routeToIssuedState")
            return await completeCallback(url: url, attemptID: nil, acceptedExternalState: state)
        }
        switch delivery {
        case .trustedEmbeddedBrowser:
            log.log("auth.callback.external.routeToTrustedEmbedded")
            return await completeCallback(url: url, attemptID: nil)
        case .external:
            return await completeUnsolicitedCallbackIfApproved(url)
        }
    }

    /// Ask the user before an unsolicited stateless callback signs the app in.
    private func completeUnsolicitedCallbackIfApproved(_ url: URL) async -> Bool {
        guard let payload = callbackRouter.callbackPayload(from: url) else {
            log.log("auth.callback.unsolicited.reject reason=invalidPayload")
            if !signedOutSinceLastAttempt { lastFailure = .invalidCallback }
            return false
        }
        guard !isAwaitingCallbackApproval else {
            log.log("auth.callback.unsolicited.reject reason=approvalAlreadyPending")
            return false
        }
        let request = UnsolicitedAuthCallbackApprovalRequest(
            accountEmail: payload.claimedEmail,
            currentAccountEmail: coordinator.isAuthenticated ? coordinator.currentUser?.primaryEmail : nil,
            replacesSignedInSession: coordinator.isAuthenticated
        )
        log.log("auth.callback.unsolicited.askApproval replaces=\(request.replacesSignedInSession)")
        isAwaitingCallbackApproval = true
        let approved = await approveUnsolicitedCallback(request)
        isAwaitingCallbackApproval = false
        guard approved else {
            log.log("auth.callback.unsolicited.reject reason=notApproved")
            return false
        }
        // The prompt promised no replacement; never replace a session that
        // appeared while it was open.
        if !request.replacesSignedInSession, coordinator.isAuthenticated {
            log.log("auth.callback.unsolicited.reject reason=sessionAppearedDuringApproval")
            return false
        }
        log.log("auth.callback.unsolicited.approved")
        return await completeCallback(url: url, attemptID: nil)
    }

    /// Sign out and prevent a late callback from resurrecting the session.
    public func signOut() async {
        if await signOutCoordinator.joinActive() { return }
        log.log("auth.browser.signOut.begin signingIn=\(isSigningIn) activeAttempt=\(activeAttemptID.map(String.init) ?? "nil") generation=\(signOutGeneration)")
        signOutGeneration &+= 1
        signedOutAtAttempt = nextAttemptID
        lastFailure = nil
        cancelActiveAttempt()
        await signOutCoordinator.run()
        log.log("auth.browser.signOut.end generation=\(signOutGeneration)")
    }

    /// Sign out with a socket deadline while sign-out continues in background.
    public func signOut(timeout: TimeInterval) async {
        // Strong capture keeps user-requested sign-out alive past caller timeout.
        let attempt = Task { @MainActor in
            await self.signOut()
            return true
        }
        _ = await deadline.resolve(attempt, timeout: timeout)
    }

    /// The active attempt's hosted sign-in URL. Switch Account adds
    /// `prompt=select_account`, so every surface that opens the attempt (the
    /// popup and the default-browser fallback) lands on the account chooser.
    private func attemptSignInURL(_ callbackState: String) -> URL {
        let url = makeSignInURL(callbackState)
        guard activeAttemptSelectsAccount,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var items = components.queryItems ?? []
        items.removeAll { $0.name == "prompt" }
        items.append(URLQueryItem(name: "prompt", value: "select_account"))
        components.queryItems = items
        return components.url ?? url
    }

    // MARK: - Attempt lifecycle

    private func startAttempt(selectAccount: Bool = false, inDefaultBrowser: Bool = false) -> Task<Bool, Never> {
        if let activeAttemptID {
            log.log("auth.browser.attempt.replace previous=\(activeAttemptID)")
        }
        cancelActiveAttempt()
        activeAttemptSelectsAccount = selectAccount
        lastFailure = nil
        nextAttemptID &+= 1
        let attemptID = nextAttemptID
        let manualCallbackState = pendingManualCallbackState
        pendingManualCallbackState = nil
        let callbackState = manualCallbackState ?? callbackStateGenerator.make()
        activeAttemptID = attemptID
        activeCallbackState = callbackState
        // The CLI's manual fallback shares this attempt's state so a late
        // callback remains valid after the popup ends (#6158).
        if let manualCallbackState {
            issueCallbackState(manualCallbackState)
        }
        isSigningIn = true
        isPresentingSignIn = true
        log.log("auth.browser.attempt.start id=\(attemptID) generation=\(signOutGeneration) state=\(redactedAuthState(callbackState))")
        scheduleAttemptTimeout(attemptID)
        scheduleSlowSignInHint(attemptID)
        let task = Task { @MainActor [weak self] in
            guard let self else { return false }
            defer { self.finishAttempt(attemptID) }
            guard self.activeAttemptID == attemptID else { return false }
            guard let result = await self.runBrowserSession(attemptID: attemptID, inDefaultBrowser: inDefaultBrowser) else {
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
                // The person closed the popup: a visible retry, not a silent return to Sign In.
                if reason == "canceled_login", !self.coordinator.isAuthenticated {
                    self.lastFailure = .browserSignInFailed("popup_closed")
                }
                return self.coordinator.isAuthenticated
            case let .failed(reason):
                self.recordBrowserSessionFailure(reason: reason, attemptID: attemptID)
                return self.coordinator.isAuthenticated
            }
        }
        activeAttemptTask = task
        return task
    }

    private func runBrowserSession(attemptID: UInt64, inDefaultBrowser: Bool) async -> HostBrowserAuthSessionResult? {
        await withCheckedContinuation {
            (continuation: CheckedContinuation<HostBrowserAuthSessionResult?, Never>) in
            activeSessionContinuation = continuation
            activeSessionContinuationAttemptID = attemptID
            if inDefaultBrowser {
                // No popup: the attempt waits for its callback, a cancel or the timeout.
                log.log("auth.browser.session.defaultBrowser id=\(attemptID)")
                continueInDefaultBrowser(attemptID: attemptID, staleReason: "staleDefaultBrowser")
                return
            }
            let callbackState = activeCallbackState ?? callbackStateGenerator.make()
            let signInURL = attemptSignInURL(callbackState)
            let scheme = callbackScheme()
            log.log("auth.browser.session.create id=\(attemptID) signInURL=\(signInURL.absoluteString) callbackScheme=\(scheme)")
            let session = sessionFactory.makeSession(signInURL: signInURL, callbackScheme: scheme) { result in
                self.log.log("auth.browser.session.completion id=\(attemptID) \(self.sessionResultSummary(result))")
                if case let .callback(url) = result, !self.callbackRouter.isAuthCallbackURL(url) {
                    self.log.log("auth.browser.session.completion.nonAuth id=\(attemptID) \(self.authCallbackSummary(url))")
                    self.continueInDefaultBrowser(attemptID: attemptID, staleReason: "staleNonAuthCallback")
                    return
                }
                // A default browser that cannot host the popup ends it at once,
                // reported as the person cancelling (cx-13h6w): nobody could
                // have acted that fast, so the sign-in goes on there instead.
                if case .cancelled(reason: "canceled_login") = result, self.endedAtOnce(attemptID) {
                    self.log.log("auth.browser.session.completion.instantCancel id=\(attemptID)")
                    self.continueInDefaultBrowser(attemptID: attemptID, staleReason: "staleInstantCancel")
                    return
                }
                self.resumeActiveSessionContinuation(returning: result, reason: "sessionCompletion", expectedAttemptID: attemptID)
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
            popupAge = (attemptID, Self.until(clock: clock, after: .seconds(instantCancelWindow)))
        }
    }

    /// Continues `attemptID` in the default browser: the popup ended without
    /// signing in, so the same sign-in page opens there and the attempt waits
    /// for its `<scheme>://auth-callback`. Opens at most once per attempt.
    private func continueInDefaultBrowser(attemptID: UInt64, staleReason: String) {
        guard activeAttemptID == attemptID, activeSessionContinuationAttemptID == attemptID else {
            log.log("auth.browser.session.completion.ignored id=\(attemptID) reason=\(staleReason) active=\(activeAttemptID.map(String.init) ?? "nil")")
            return
        }
        if let state = activeCallbackState {
            issueCallbackState(state)
        }
        cancelSlowSignInHint()
        signInIsSlow = true
        guard handedOffAttemptID != attemptID, let state = activeCallbackState else { return }
        log.log("auth.browser.handoff.continueInDefaultBrowser attempt=\(attemptID)")
        if openExternalURL(attemptSignInURL(state)) {
            // Browser launched: keep the attempt parked so the
            // eventual cmux://auth-callback resumes it. A parked handoff that
            // never gets its callback ends after the handoff wait, not the
            // popup's longer one.
            handedOffAttemptID = attemptID
            scheduleAttemptTimeout(attemptID, after: browserHandoffTimeout)
        } else {
            // No browser launched, so nothing will call back.
            // End the attempt with a failure instead of parking
            // the awaited sign-in until the timeout, so callers
            // and the UI stop waiting and the user can retry.
            log.log("auth.browser.handoff.openFailed attempt=\(attemptID)")
            resumeActiveSessionContinuation(
                returning: .failed(reason: "browser_open_failed"),
                reason: "handoffOpenFailed",
                expectedAttemptID: attemptID
            )
        }
    }

    /// Whether `attemptID`'s popup ended within `instantCancelWindow` of starting.
    private func endedAtOnce(_ attemptID: UInt64) -> Bool {
        guard let popupAge, popupAge.attemptID == attemptID else { return false }
        return popupAge.isFresh()
    }

    /// True until `window` has passed on `clock`.
    private static func until(clock: any Clock<Duration>, after window: Duration) -> @Sendable () -> Bool {
        fresh(clock: clock, for: window)
    }

    private static func fresh<C: Clock>(clock: C, for window: Duration) -> @Sendable () -> Bool
        where C.Duration == Duration {
        let deadline = clock.now.advanced(by: window)
        return { clock.now < deadline }
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
        popupAge = nil
        activeAttemptID = nil
        activeAttemptTask = nil
        handedOffAttemptID = nil
        activeCallbackState = nil
        activeSession = nil
        isSigningIn = false
        isPresentingSignIn = false
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
        popupAge = nil
        cancelRateLimitWait()
        activeAttemptID = nil
        activeAttemptTask = nil
        handedOffAttemptID = nil
        activeCallbackState = nil
        issuedCallbackStates.removeAll()
        activeSession?.cancel()
        activeSession = nil
        isSigningIn = false
        isPresentingSignIn = false
    }

    /// Arms the attempt's deadline, replacing any earlier one. `seconds` nil uses ``browserAttemptTimeout``.
    private func scheduleAttemptTimeout(_ attemptID: UInt64, after seconds: TimeInterval? = nil) {
        activeAttemptTimeoutTask?.cancel()
        let timeout = seconds ?? browserAttemptTimeout
        guard timeout > 0 else {
            activeAttemptTimeoutTask = nil
            return
        }
        let clock = self.clock
        activeAttemptTimeoutTask = Task { @MainActor [weak self] in
            try? await clock.sleep(for: .seconds(timeout))
            guard !Task.isCancelled, let self, self.activeAttemptID == attemptID else { return }
            self.log.log("auth.browser.attempt.timeout id=\(attemptID) timeoutSeconds=\(Int(timeout))")
            // A retryable browser failure: the UI names the browser step, and the
            // detail reads `browser_timeout` for a bug report.
            self.lastFailure = .browserSignInFailed("browser_timeout")
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

    /// Clears the rate-limit wait state when `epoch` still owns it.
    private func endRateLimitWait(_ epoch: UInt64?) {
        guard let epoch, epoch == rateLimitEpoch else { return }
        isRetryingAfterRateLimit = false
    }

    /// Cancels any pending rate-limit wait and its UI state.
    private func cancelRateLimitWait() {
        for wait in rateLimitWaits.values { wait.cancel() }
        rateLimitWaits.removeAll()
        rateLimitEpoch &+= 1
        isRetryingAfterRateLimit = false
    }

    private static func milliseconds(_ duration: Duration) -> Int64 {
        let parts = duration.components
        return parts.seconds * 1000 + parts.attoseconds / 1_000_000_000_000_000
    }

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
            guard HostBrowserIssuedCallbackStates.constantTimeEquals(authCallbackState(from: url), activeCallbackState) else {
                log.log("auth.callback rejected: state mismatch attempt=\(attemptID)")
                lastFailure = .invalidCallback
                return false
            }
        } else if let state = authCallbackState(from: url),
                  !HostBrowserIssuedCallbackStates.constantTimeEquals(state, acceptedExternalState) {
            log.log("auth.callback rejected: stateful external callback without active attempt")
            lastFailure = .invalidCallback
            return false
        }
        let generation = signOutGeneration
        if let attemptID { completingAttemptID = attemptID }
        defer { if completingAttemptID == attemptID { completingAttemptID = nil } }
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
        // A 429 from the sign-in service is retried here, keeping the seeded
        // tokens: the callback already proved the sign-in, only the user
        // fetch was refused. The retry count and each wait are bounded.
        var rateLimitRetries = 0
        var ownedRateLimitEpoch: UInt64?
        defer { endRateLimitWait(ownedRateLimitEpoch) }
        while true {
            do {
                log.log("auth.callback.coordinator.complete.begin attempt=\(attemptID.map(String.init) ?? "external") retry=\(rateLimitRetries)")
                // This loop reports its own 429s with the backoff it chooses.
                let coordinator = self.coordinator
                try await StackAuthRateLimitReporting.$callerReports.withValue(true) {
                    try await coordinator.completeExternalSignIn()
                }
                coordinator.rateLimitTelemetry.succeeded(.signInCompletion)
                break
            } catch {
                log.log("auth.callback completion failed: \(error)")
                guard signOutGeneration == generation,
                      attemptID == nil || activeAttemptID == attemptID
                else {
                    return false
                }
                if let rateLimit = AuthRateLimit(error: error),
                   rateLimitRetries < AuthRateLimit.maximumRetries,
                   !Task.isCancelled {
                    rateLimitRetries += 1
                    let delay = AuthRateLimit.delay(
                        retryAfter: rateLimit.retryAfter,
                        retry: rateLimitRetries,
                        jitter: Double.random(in: 0.5...1.0)
                    )
                    coordinator.rateLimitTelemetry.rateLimited(
                        .signInCompletion, rateLimit: rateLimit, backoff: delay, attempt: rateLimitRetries
                    )
                    log.log("auth.callback.rateLimited attempt=\(attemptID.map(String.init) ?? "external") retry=\(rateLimitRetries) retryAfterMs=\(rateLimit.retryAfter.map { String(Self.milliseconds($0)) } ?? "nil") delayMs=\(Self.milliseconds(delay))")
                    lastFailure = .rateLimited
                    isRetryingAfterRateLimit = true
                    rateLimitEpoch &+= 1
                    ownedRateLimitEpoch = rateLimitEpoch
                    let clock = self.clock
                    let epoch = rateLimitEpoch
                    let wait = Task<Void, Never> { _ = try? await clock.sleep(for: delay) }
                    rateLimitWaits[epoch] = wait
                    await wait.value
                    rateLimitWaits[epoch] = nil
                    guard !Task.isCancelled,
                          !wait.isCancelled,
                          signOutGeneration == generation,
                          attemptID == nil || activeAttemptID == attemptID
                    else {
                        log.log("auth.callback.rateLimited.abandon attempt=\(attemptID.map(String.init) ?? "external") generation=\(signOutGeneration)")
                        return false
                    }
                    continue
                }
                if let rateLimit = AuthRateLimit(error: error) {
                    // Out of retries: the 429 still counts, with no further wait.
                    coordinator.rateLimitTelemetry.rateLimited(
                        .signInCompletion, rateLimit: rateLimit, backoff: .zero, attempt: rateLimitRetries + 1
                    )
                }
                let displaySafe: AuthError = AuthRateLimit(error: error) != nil
                    ? .rateLimited
                    : AuthError(displaySafe: error) ?? .serverError(0, "auth_failed")
                if displaySafe != .cancelled {
                    lastFailure = displaySafe
                    lastFailureDetail = coordinator.lastExternalSignInFailureDetail
                        ?? AuthError.failureDetail(for: error)
                } else if rateLimitRetries > 0, lastFailure == .rateLimited {
                    // This loop set the rate-limit state; a cancelled retry
                    // must not leave it on screen.
                    lastFailure = nil
                }
                // Do not clear seeds here. The coordinator owns raced sign-out
                // teardown credentials and concurrent publish cancellation.
                return false
            }
        }
        endRateLimitWait(ownedRateLimitEpoch)
        log.log("auth.callback.coordinator.complete.end attempt=\(attemptID.map(String.init) ?? "external") signedIn=\(coordinator.isAuthenticated)")
        guard signOutGeneration == generation else {
            // Sign-out ran while the validation round trip was in flight. The
            // user's intent wins. Join the prepared flow-level operation so
            // this rollback cannot clear auth before composition-owned state
            // has been durably quarantined.
            log.log("auth.callback.coordinator.rollback attempt=\(attemptID.map(String.init) ?? "external") reason=signOutRaced generation=\(signOutGeneration)")
            await signOut()
            await tokenStore.clearTokensIfCurrent(
                accessToken: payload.accessToken,
                refreshToken: payload.refreshToken
            )
            return false
        }
        if let state = authCallbackState(from: url) {
            // Single use: the popup's state may also have been issued for the
            // default-browser fallback.
            issuedCallbackStates.remove(state)
        }
        lastFailure = nil
        return true
    }

    /// Register an app-issued state for use after the popup ends. It lives
    /// as long as an abandoned attempt would.
    private func issueCallbackState(_ state: String) {
        let lifetime = browserAttemptTimeout > 0 ? browserAttemptTimeout : 10 * 60
        issuedCallbackStates.issue(state, clock: clock, lifetime: .seconds(lifetime))
    }

    /// Detach the session continuation so later session completions, attempt
    /// replacement and sign-out cannot resume it; the caller must resume it.
    private func takeActiveSessionContinuation() -> CheckedContinuation<HostBrowserAuthSessionResult?, Never>? {
        let continuation = activeSessionContinuation
        activeSessionContinuation = nil
        activeSessionContinuationAttemptID = nil
        return continuation
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

}
