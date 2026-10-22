import CmuxProductAnalytics

/// Turns account observations into analytics actions: identify on sign-in,
/// a success or failure for each sign-in the user started, and sign-out. Pure, so the transitions are unit tested without auth.
struct AccountAnalyticsState: Equatable {
    enum Action: Equatable {
        case identify(userID: String)
        case signInSucceeded
        case signInFailed(SignInFailureReason)
        case signedOut
    }

    private(set) var userID: String?
    /// A user-started sign-in has no result yet. Session restore never sets it.
    private(set) var isSignInPending = false
    private var reportedFailure: SignInFailureReason?

    mutating func signInStarted() {
        isSignInPending = true
        reportedFailure = nil
    }

    /// - Parameters:
    ///   - userID: The signed-in Stack user id, or nil.
    ///   - isSettling: A restore or sign-in is still running, so nil is not yet signed out.
    ///   - failure: The browser sign-in's latest failure.
    mutating func observe(
        userID newUserID: String?,
        isSettling: Bool,
        failure: SignInFailureReason?
    ) -> [Action] {
        var actions: [Action] = []
        if let newUserID {
            if newUserID != userID {
                actions.append(.identify(userID: newUserID))
            }
            if userID != newUserID, isSignInPending {
                actions.append(.signInSucceeded)
                isSignInPending = false
            }
            userID = newUserID
        } else if !isSettling, userID != nil {
            actions.append(.signedOut)
            userID = nil
        }
        if isSignInPending, let failure, failure != reportedFailure {
            actions.append(.signInFailed(failure))
            reportedFailure = failure
            isSignInPending = false
        }
        return actions
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
