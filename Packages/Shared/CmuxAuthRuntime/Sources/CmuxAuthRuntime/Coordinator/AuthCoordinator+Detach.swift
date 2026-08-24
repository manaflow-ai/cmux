import Foundation

extension AuthCoordinator {
    /// Detach the published session WITHOUT touching the token store: the
    /// "park" half of a backend-environment switch.
    ///
    /// Assembled from the exact local pieces of
    /// ``signOut(onSignedOut:teardownTimeout:)`` that end the published
    /// session, and nothing else:
    ///
    /// 1. cancel every in-flight sign-in exchange, session validation,
    ///    post-sign-in hook, and token-touching phase (the SDK's token-write
    ///    chokepoint then refuses a parked exchange's late store write),
    /// 2. advance the session generation (announcing the transition) and bump
    ///    the sign-out epoch, so any flow parked across this call takes its
    ///    rollback path instead of publishing over the detach,
    /// 3. clear the sign-in phase timeouts,
    /// 4. drop `latestSignInRefreshToken` and clear the published auth state
    ///    plus the self-healing caches (cached user, has-tokens flag, teams).
    ///
    /// Deliberately absent, in contrast to sign-out: NO
    /// `client.clearLocalSession()` (the tokens stay in this project's slot,
    /// parked for the return switch), NO `onSignedOut` hook and NO
    /// `revokeSession` (the parked session must stay valid server-side), and
    /// NO bounded teardown group (there is no server tail to bound).
    ///
    /// Residual risk (same loss class as today's raced sign-out): a sign-in
    /// exchange whose store write already raced past the cancellation
    /// chokepoint before this detach ran takes the stale-completion rollback
    /// in `completeSignIn`, whose `clearLocalSession()` clears the OLD slot
    /// even though this detach meant to park it. The window is the same one
    /// interactive sign-out already accepts; the parked session is then
    /// simply absent on return and the user signs in again.
    public func detachSessionLeavingTokens() async {
        log.log("auth.detach: parking session (tokens left in store)")
        for exchange in activeSignInExchanges.values { exchange.task.cancel() }
        for validation in activeSessionValidations.values { validation.cancel() }
        cancelPostSignInHooksForSignOut()
        for phase in activeTokenTouchingPhases.values { phase.cancel() }
        advanceSessionGeneration()
        signOutEpoch &+= 1
        publishAuthenticatedSessionIdentity()
        await phaseTimeoutRegistry.clear([.sendCode, .verifyCode, .passwordSignIn, .oauth, .validateSession])
        latestSignInRefreshToken = nil
        clearAuthState(sessionTransitionAlreadyAnnounced: true)
    }
}
