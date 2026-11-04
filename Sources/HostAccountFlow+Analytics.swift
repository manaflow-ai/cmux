import CmuxAuthRuntime
import CmuxProductAnalytics

extension HostAccountFlow {
    /// Reports sign-in, identity, team and sign-out changes. Called on every
    /// coordinator change and once at init; cheap when nothing changed.
    func syncAnalytics() {
        // A 429 that is still being retried is not a result; the retry's
        // success or its final failure is.
        let failure = isRetryingAfterRateLimit ? nil : lastSignInFailure
        reportAnalytics(analyticsState.observe(
            userID: coordinator.currentUser?.id,
            isSettling: isWorkingOnAuth,
            failure: AccountAnalyticsState.reason(failure)
        ))
    }

    /// A sign-in step from the browser flow.
    func noteSignInFlowEvent(_ event: HostBrowserSignInEvent) {
        // On completion the coordinator already holds the signed-in user, and
        // on a callback failure the flow already holds its failure.
        reportAnalytics(analyticsState.flowEvent(
            event,
            userID: coordinator.currentUser?.id,
            failure: AccountAnalyticsState.reason(lastSignInFailure)
        ))
    }

    /// `cmux_signed_out` is captured before a sign-out runs so it joins the
    /// account. If the account is still signed in afterwards (a failed or
    /// no-op sign-out), later events get the signed-in context back.
    func restoreAnalyticsIfStillSignedIn() {
        guard let userID = coordinator.currentUser?.id else { return }
        analytics.identify(userID: userID)
    }

    func noteSignInStarted(_ entrypoint: SignInEntrypoint) {
        reportAnalytics(analyticsState.signInStarted(entrypoint))
    }

    /// Captures `cmux_signed_out` before the sign-out runs and ends any open
    /// attempt, which the sign-out cancels.
    func noteSignOutRequested() {
        analyticsState.signOutRequested()
        analytics.signedOut()
    }

    private func reportAnalytics(_ actions: [AccountAnalyticsState.Action]) {
        for action in actions {
            switch action {
            case let .identify(userID):
                analytics.identify(userID: userID)
            case let .signInStarted(attempt, entrypoint, replaced):
                analytics.track(.signInStarted(attemptID: attempt, entrypoint: entrypoint, replacedAttemptID: replaced))
            case let .signInCallbackReceived(attempt, delivery, link):
                analytics.track(.signInCallbackReceived(attemptID: attempt, delivery: delivery, link: link))
            case let .signInWindowClosed(attempt):
                analytics.track(.signInWindowClosed(attemptID: attempt))
            case let .signInSucceeded(attempt, link):
                analytics.track(.signInSucceeded(attemptID: attempt, link: link))
            case let .signInFailed(reason, attempt):
                analytics.track(.signInFailed(reason: reason, attemptID: attempt))
            case .signedOut:
                analytics.signedOut()
            }
        }
    }
}
