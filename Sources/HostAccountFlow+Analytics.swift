import CmuxAuthRuntime
import CmuxProductAnalytics
import Foundation

extension HostAccountFlow {
    /// Reports sign-in, identity, team and sign-out changes. Called on every
    /// coordinator change and once at init; cheap when nothing changed.
    func syncAnalytics() {
        // Failures come only from flow events, so a 429 that is still being
        // retried (no event) is never one.
        reportAnalytics(analyticsState.observe(
            userID: coordinator.currentUser?.id,
            isSettling: isWorkingOnAuth
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

    /// Runs `open` (a synchronous `beginSignIn`) as a user sign-in request
    /// from `entrypoint`. Every request sends `cmux_sign_in_started`: with the
    /// attempt it opened, or as `withoutAttempt` when it opened none.
    func withSignInRequest<Result>(
        _ entrypoint: SignInEntrypoint,
        withoutAttempt outcome: SignInStartOutcome,
        _ open: () -> Result
    ) -> Result {
        let request = analyticsState.signInRequested(entrypoint)
        defer { reportAnalytics(analyticsState.signInRequestEnded(request, withoutAttempt: outcome)) }
        return open()
    }

    /// The async variant, for the socket sign-in.
    func withAsyncSignInRequest<Result>(
        _ entrypoint: SignInEntrypoint,
        withoutAttempt outcome: SignInStartOutcome,
        _ open: () async -> Result
    ) async -> Result {
        let request = analyticsState.signInRequested(entrypoint)
        let result = await open()
        reportAnalytics(analyticsState.signInRequestEnded(request, withoutAttempt: outcome))
        return result
    }

    /// Query items that let the hosted sign-in page report its steps for an
    /// opened attempt: an opt-in flag and the attempt's random id. Only while
    /// product analytics is on for this launch (Settings opt-in, managed
    /// `DisableTelemetry`, never under XCTest or in debug builds); otherwise
    /// the sign-in URL is unchanged.
    func hostedSignInAnalyticsQueryItems(for browserAttempt: HostBrowserSignInAttempt) -> [URLQueryItem] {
        guard analytics.isEnabled, let attemptID = analyticsState.attemptID(for: browserAttempt) else { return [] }
        return [
            URLQueryItem(name: Self.hostedAnalyticsQueryName, value: "1"),
            URLQueryItem(name: Self.hostedAttemptQueryName, value: attemptID.token),
        ]
    }

    static let hostedAnalyticsQueryName = "cmux_analytics"
    static let hostedAttemptQueryName = "cmux_attempt"

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
            case let .signInStarted(entrypoint, start):
                analytics.track(.signInStarted(entrypoint: entrypoint, start: start))
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
