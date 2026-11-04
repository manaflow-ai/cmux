import CmuxAuthRuntime
import CmuxProductAnalytics

/// Turns account observations and browser sign-in steps into analytics
/// actions: identify on sign-in, one attempt id per user-started sign-in, the
/// attempt's callback and window close, a success or failure for it, and
/// sign-out. Pure, so the transitions are tested without auth.
///
/// A callback is credited to the started sign-in whose browser attempt issued
/// the state it carried, which can be an earlier, replaced one. A stateless
/// callback (the embedded browser's handoff, an approved unsolicited one) has
/// no such link; it is credited to the pending sign-in with
/// `attempt_link = none`, never as a proven link.
struct AccountAnalyticsState: Equatable {
    enum Action: Equatable {
        case identify(userID: String)
        case signInStarted(SignInAttemptID, SignInEntrypoint, replaced: SignInAttemptID?)
        case signInCallbackReceived(SignInAttemptID, SignInCallbackDelivery, SignInAttemptLink)
        case signInWindowClosed(SignInAttemptID)
        case signInSucceeded(SignInAttemptID, SignInAttemptLink)
        case signInFailed(SignInFailureReason, SignInAttemptID)
        case signedOut
    }

    private struct Attempt: Equatable {
        let id: SignInAttemptID
        var browserAttempts: Set<HostBrowserSignInAttempt> = []
        var reportedCallback = false
        var reportedWindowClosed = false
        var hasResult = false
    }

    /// The latest started sign-ins, newest last. Bounded to eight: a callback
    /// whose state an evicted (ninth-newest or older) attempt issued is not
    /// reported, so its callback and result go unmeasured rather than being
    /// credited to another attempt.
    private var attempts: [Attempt] = []
    private static let maximumAttempts = 8

    /// The entrypoint of a user request whose browser attempt has not opened
    /// yet. Set and cleared around the synchronous `beginSignIn` call.
    private var requestedEntrypoint: SignInEntrypoint?

    private(set) var userID: String?
    /// The user-started sign-in that has no result yet. Session restore never
    /// sets it.
    private(set) var pendingAttempt: SignInAttemptID?
    var isSignInPending: Bool { pendingAttempt != nil }
    private var reportedFailure: SignInFailureReason?

    /// The user asked for a sign-in from `entrypoint`. It becomes a started
    /// sign-in only when the browser flow opens an attempt for it (an
    /// already signed-in socket call or a reused handed-off window opens none).
    mutating func signInRequested(_ entrypoint: SignInEntrypoint) {
        requestedEntrypoint = entrypoint
    }

    /// The synchronous request is over; an unconsumed request is dropped.
    mutating func signInRequestEnded() {
        requestedEntrypoint = nil
    }

    /// Starts a new attempt. A still-pending earlier attempt is replaced: it
    /// gets no result of its own unless its browser state later completes.
    mutating func signInStarted(
        _ entrypoint: SignInEntrypoint,
        attemptID: SignInAttemptID = SignInAttemptID()
    ) -> [Action] {
        let replaced = pendingAttempt
        pendingAttempt = attemptID
        reportedFailure = nil
        attempts.append(Attempt(id: attemptID))
        if attempts.count > Self.maximumAttempts {
            attempts.removeFirst(attempts.count - Self.maximumAttempts)
        }
        return [.signInStarted(attemptID, entrypoint, replaced: replaced)]
    }

    /// The user asked to sign out. The browser flow cancels any open attempt
    /// and drops every kept state, so no earlier attempt can complete.
    mutating func signOutRequested() {
        pendingAttempt = nil
        attempts.removeAll()
    }

    /// - Parameters:
    ///   - userID: The signed-in Stack user id, or nil.
    ///   - isSettling: A restore or sign-in is still running, so nil is not yet signed out.
    ///   - failure: The browser sign-in's latest failure, nil while a 429 is
    ///     still being retried.
    mutating func observe(
        userID newUserID: String?,
        isSettling: Bool,
        failure: SignInFailureReason?
    ) -> [Action] {
        var actions = noteUser(newUserID)
        if newUserID == nil, !isSettling, userID != nil {
            actions.append(.signedOut)
            userID = nil
        }
        // A failure the flow set outside a callback (timeout, browser failure,
        // a callback it refused before completion) belongs to its live
        // attempt, the newest start. Callback failures arrive first through
        // `flowEvent` with their own attempt and set `reportedFailure`.
        if let pending = pendingAttempt, let failure, failure != reportedFailure {
            actions.append(.signInFailed(failure, pending))
            reportedFailure = failure
            markResult(pending)
            pendingAttempt = nil
        }
        return actions
    }

    /// A step reported by the browser sign-in flow. Steps of no user-started
    /// sign-in (restore, unsolicited callbacks while none is pending) report
    /// nothing. Success comes only from the flow's completion, so a sign-in
    /// that ends on the account already signed in is counted too.
    /// - Parameters:
    ///   - userID: The signed-in Stack user id after the step.
    ///   - failure: The flow's failure after the step; read for `callbackFailed`.
    mutating func flowEvent(
        _ event: HostBrowserSignInEvent,
        userID currentUserID: String?,
        failure: SignInFailureReason?
    ) -> [Action] {
        switch event {
        case let .attemptStarted(browserAttempt):
            // Only a browser attempt the user asked for through this flow is
            // measured; one opened by another caller stays unmeasured rather
            // than joining a stale pending sign-in.
            guard let entrypoint = requestedEntrypoint else { return [] }
            requestedEntrypoint = nil
            let actions = signInStarted(entrypoint)
            attempts[attempts.count - 1].browserAttempts.insert(browserAttempt)
            return actions
        case let .callbackReceived(source, browserAttempt):
            guard let (index, link) = credit(browserAttempt), !attempts[index].reportedCallback else { return [] }
            attempts[index].reportedCallback = true
            return [.signInCallbackReceived(attempts[index].id, Self.delivery(source), link)]
        case let .windowClosedByUser(browserAttempt):
            guard let (index, _) = credit(browserAttempt),
                  attempts[index].id == pendingAttempt,
                  !attempts[index].reportedCallback,
                  !attempts[index].reportedWindowClosed
            else { return [] }
            attempts[index].reportedWindowClosed = true
            return [.signInWindowClosed(attempts[index].id)]
        case let .callbackFailed(browserAttempt):
            return callbackFailure(failure, index: credit(browserAttempt)?.0)
        case let .callbackRefused(browserAttempt):
            // A refused callback names only the attempt that issued its state;
            // one no tracked attempt issued belongs to none, not the newest.
            return callbackFailure(failure, index: browserAttempt.flatMap { credit($0)?.0 })
        case let .signInCompleted(browserAttempt):
            // Identify first, as a sign-in that changes the account does.
            var actions = noteUser(currentUserID)
            if let (index, link) = credit(browserAttempt), !attempts[index].hasResult {
                attempts[index].hasResult = true
                actions.append(.signInSucceeded(attempts[index].id, link))
            }
            // The app is signed in, and a callback carrying an earlier
            // attempt's state also ends the live one, so the pending start
            // has no result left to wait for.
            pendingAttempt = nil
            return actions
        }
    }

    /// A failure the flow set for one callback. Reported here or not at all:
    /// `observe` must not also credit it to the newest start, whose window
    /// may still be open and succeed.
    private mutating func callbackFailure(_ failure: SignInFailureReason?, index: Int?) -> [Action] {
        guard let failure else { return [] }
        reportedFailure = failure
        guard let index, !attempts[index].hasResult else { return [] }
        attempts[index].hasResult = true
        if attempts[index].id == pendingAttempt { pendingAttempt = nil }
        return [.signInFailed(failure, attempts[index].id)]
    }

    private mutating func noteUser(_ newUserID: String?) -> [Action] {
        guard let newUserID, newUserID != userID else { return [] }
        userID = newUserID
        return [.identify(userID: newUserID)]
    }

    /// The started sign-in a step belongs to, and how it is linked.
    private func credit(_ browserAttempt: HostBrowserSignInAttempt?) -> (Int, SignInAttemptLink)? {
        if let browserAttempt {
            guard let index = attempts.lastIndex(where: { $0.browserAttempts.contains(browserAttempt) }) else {
                return nil
            }
            return (index, .state)
        }
        guard let pending = pendingAttempt, let index = index(of: pending) else { return nil }
        return (index, .unlinked)
    }

    private func index(of id: SignInAttemptID) -> Int? {
        attempts.lastIndex { $0.id == id }
    }

    private mutating func markResult(_ id: SignInAttemptID) {
        if let index = index(of: id) { attempts[index].hasResult = true }
    }

    static func delivery(_ source: HostBrowserCallbackSource) -> SignInCallbackDelivery {
        switch source {
        case .signInWindow: .signInWindow
        case .external: .external
        case .embeddedBrowser: .embeddedBrowser
        }
    }

    static func reason(_ failure: AccountSignInModel.Failure?) -> SignInFailureReason? {
        guard let failure else { return nil }
        return switch failure {
        case .cancelled: .cancelled
        case .offline: .offline
        case .network, .unknown: .network
        case .timedOut: .timedOut
        case .server: .server
        case .invalidLink: .invalidLink
        case .browserUnavailable: .browserUnavailable
        case .unauthorized: .unauthorized
        case .rejected: .rejected
        case .rateLimited: .rateLimited
        }
    }
}
