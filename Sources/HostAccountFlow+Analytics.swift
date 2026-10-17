import CmuxProductAnalytics

extension HostAccountFlow {
    /// Reports sign-in, identity, team and sign-out changes. Called on every
    /// coordinator change and once at init; cheap when nothing changed.
    func syncAnalytics() {
        let actions = analyticsState.observe(
            userID: coordinator.currentUser?.id,
            isSettling: isWorkingOnAuth,
            failure: AccountAnalyticsState.reason(lastSignInFailure)
        )
        for action in actions {
            switch action {
            case let .identify(userID):
                analytics.identify(userID: userID)
            case .signInSucceeded:
                analytics.track(.signInSucceeded)
            case let .signInFailed(reason):
                analytics.track(.signInFailed(reason: reason))
            case .signedOut:
                analytics.signedOut()
            }
        }
    }

    /// `cmux_signed_out` is captured before a sign-out runs so it joins the
    /// account. If the account is still signed in afterwards (a failed or
    /// no-op sign-out), later events get the signed-in context back.
    func restoreAnalyticsIfStillSignedIn() {
        guard let userID = coordinator.currentUser?.id else { return }
        analytics.identify(userID: userID)
    }

    func noteSignInStarted() {
        analyticsState.signInStarted()
        analytics.track(.signInStarted)
    }
}
