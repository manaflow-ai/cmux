import CmuxProductAnalytics

extension HostAccountFlow {
    /// Reports sign-in, identity, team and sign-out changes. Called on every
    /// coordinator change and once at init; cheap when nothing changed.
    func syncAnalytics() {
        let actions = analyticsState.observe(
            userID: coordinator.currentUser?.id,
            teamID: confirmedTeamID,
            isSettling: isWorkingOnAuth,
            failure: AccountAnalyticsState.reason(lastSignInFailure)
        )
        for action in actions {
            switch action {
            case let .identify(userID, teamID):
                analytics.identify(userID: userID, teamID: teamID)
            case .signInSucceeded:
                analytics.track(.signInSucceeded)
            case let .signInFailed(reason):
                analytics.track(.signInFailed(reason: reason))
            case .signedOut:
                analytics.signedOut()
            }
        }
    }

    func noteSignInStarted() {
        analyticsState.signInStarted()
        analytics.track(.signInStarted)
    }
}
