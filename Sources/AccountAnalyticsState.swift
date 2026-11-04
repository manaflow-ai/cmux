import CmuxAuthRuntime
import CmuxProductAnalytics

/// Turns account observations and browser sign-in steps into analytics
/// actions: identify on sign-in, one start per user sign-in request, one
/// attempt id per request that opened a browser attempt, the attempt's
/// callback and window close, a success or failure for it, and sign-out.
/// Pure, so the transitions are tested without auth.
///
/// A callback is credited to the started sign-in whose browser attempt issued
/// the state it carried, which can be an earlier, replaced one. A stateless
/// callback (the embedded browser's handoff, an approved unsolicited one) has
/// no such link; it is credited to the pending sign-in with
/// `attempt_link = none`, never as a proven link.
struct AccountAnalyticsState: Equatable {
    enum Action: Equatable {
        case identify(userID: String)
        case signInStarted(SignInEntrypoint, SignInStart)
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
        /// At most one failure and one success per attempt. A success can
        /// follow a failure (a kept state completed after the deadline or a
        /// browser failure); a failure never follows a success.
        var reportedFailure = false
        var reportedSuccess = false
    }

    /// The latest started sign-ins, newest last. Bounded to eight: a callback
    /// whose state an evicted (ninth-newest or older) attempt issued is not
    /// reported, so its callback and result go unmeasured rather than being
    /// credited to another attempt.
    private var attempts: [Attempt] = []
    private static let maximumAttempts = 8

    /// One user sign-in request, from its start until the call that serves
    /// it returns.
    struct Request: Equatable {
        fileprivate let id: UInt64
        let entrypoint: SignInEntrypoint
    }

    /// The request whose call is running. The browser flow opens its attempt
    /// synchronously inside that call, so an attempt opened now is its.
    private var currentRequest: Request?
    private var openedRequests: Set<UInt64> = []
    private var nextRequestID: UInt64 = 0

    private(set) var userID: String?
    /// The user-started sign-in that has no result yet. Session restore never
    /// sets it.
    private(set) var pendingAttempt: SignInAttemptID?
    var isSignInPending: Bool { pendingAttempt != nil }

    /// The user asked to sign in from `entrypoint`. Its start is reported
    /// when the browser flow opens an attempt for it (`opened`), or else when
    /// the request ends.
    mutating func signInRequested(_ entrypoint: SignInEntrypoint) -> Request {
        nextRequestID &+= 1
        let request = Request(id: nextRequestID, entrypoint: entrypoint)
        currentRequest = request
        return request
    }

    /// The call that served `request` returned. A request that opened no
    /// attempt is reported now, as `outcome`; it creates no pending attempt,
    /// so it cannot take a later step's attribution.
    mutating func signInRequestEnded(_ request: Request, withoutAttempt outcome: SignInStartOutcome) -> [Action] {
        if currentRequest == request { currentRequest = nil }
        guard openedRequests.remove(request.id) == nil else { return [] }
        return [.signInStarted(request.entrypoint, .noAttempt(outcome))]
    }

    /// Starts a new attempt. A still-pending earlier attempt is replaced: it
    /// gets no result of its own unless its browser state later completes.
    mutating func signInStarted(
        _ entrypoint: SignInEntrypoint,
        attemptID: SignInAttemptID = SignInAttemptID()
    ) -> [Action] {
        let replaced = pendingAttempt
        pendingAttempt = attemptID
        attempts.append(Attempt(id: attemptID))
        if attempts.count > Self.maximumAttempts {
            attempts.removeFirst(attempts.count - Self.maximumAttempts)
        }
        return [.signInStarted(entrypoint, .opened(attemptID, replaced: replaced))]
    }

    /// The user asked to sign out. The browser flow cancels any open attempt
    /// and drops every kept state, so no earlier attempt can complete.
    mutating func signOutRequested() {
        pendingAttempt = nil
        attempts.removeAll()
    }

    /// Identity and sign-out only. Every failure comes from a flow event that
    /// names its attempt, so none is inferred from the flow's latest failure.
    /// - Parameters:
    ///   - userID: The signed-in Stack user id, or nil.
    ///   - isSettling: A restore or sign-in is still running, so nil is not yet signed out.
    mutating func observe(userID newUserID: String?, isSettling: Bool) -> [Action] {
        var actions = noteUser(newUserID)
        if newUserID == nil, !isSettling, userID != nil {
            actions.append(.signedOut)
            userID = nil
        }
        return actions
    }

    /// A step reported by the browser sign-in flow. Steps of no user-started
    /// sign-in (restore, unsolicited callbacks while none is pending) report
    /// nothing. Success comes only from the flow's completion, so a sign-in
    /// that ends on the account already signed in is counted too.
    /// - Parameters:
    ///   - userID: The signed-in Stack user id after the step.
    ///   - failure: The flow's failure after the step; read for failure steps.
    mutating func flowEvent(
        _ event: HostBrowserSignInEvent,
        userID currentUserID: String?,
        failure: SignInFailureReason?
    ) -> [Action] {
        switch event {
        case let .attemptStarted(browserAttempt):
            // Only a browser attempt opened by a user request is measured;
            // one opened by another caller stays unmeasured rather than
            // joining a stale pending sign-in.
            guard let request = currentRequest, !openedRequests.contains(request.id) else { return [] }
            openedRequests.insert(request.id)
            let actions = signInStarted(request.entrypoint)
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
        case let .attemptFailed(browserAttempt):
            return attemptFailure(failure, index: credit(browserAttempt)?.0)
        case let .callbackFailed(browserAttempt):
            return attemptFailure(failure, index: credit(browserAttempt)?.0)
        case let .callbackRefused(browserAttempt):
            // A refused callback names only the attempt that issued its state;
            // one no tracked attempt issued belongs to none, not the newest.
            return attemptFailure(failure, index: browserAttempt.flatMap { credit($0)?.0 })
        case let .signInCompleted(browserAttempt):
            // Identify first, as a sign-in that changes the account does.
            var actions = noteUser(currentUserID)
            if let (index, link) = credit(browserAttempt), !attempts[index].reportedSuccess {
                attempts[index].reportedSuccess = true
                actions.append(.signInSucceeded(attempts[index].id, link))
            }
            // The app is signed in, and a callback carrying an earlier
            // attempt's state also ends the live one, so the pending start
            // has no result left to wait for.
            pendingAttempt = nil
            return actions
        }
    }

    /// A failure of the attempt at `index`, once per attempt and never after
    /// its success. Another attempt's failure, even with the same reason, is
    /// that attempt's own.
    private mutating func attemptFailure(_ failure: SignInFailureReason?, index: Int?) -> [Action] {
        guard let failure, let index,
              !attempts[index].reportedFailure, !attempts[index].reportedSuccess
        else { return [] }
        attempts[index].reportedFailure = true
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
