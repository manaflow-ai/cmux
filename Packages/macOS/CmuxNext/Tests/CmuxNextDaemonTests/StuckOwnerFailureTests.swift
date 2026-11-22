import Testing
@testable import CmuxNextDaemon

/// The gate of "Restart cmux-tui": a plain `server ensure` that failed the way a
/// stuck owner makes it fail. An owner at its connection limit whose clients never
/// leave fails ensure with `server.busy` (https://github.com/manaflow-ai/cmux/issues/22311),
/// and only Restart recovers it.
struct StuckOwnerFailureTests {
    private func ensureFailure(_ code: String) -> DaemonError {
        .launchFailed(#"exit 3: {"code":"\#(code)","message":"m","details":{},"retryable":false}"#)
    }

    @Test func anOwnerAtItsConnectionLimitOffersRestart() {
        #expect(DaemonLauncher.isStuckOwnerFailure(ensureFailure("server.busy")))
        #expect(DaemonLauncher.isStuckOwnerFailure(ensureFailure("server.unavailable")))
    }

    @Test func otherEnsureFailuresDoNotOfferRestart() {
        #expect(!DaemonLauncher.isStuckOwnerFailure(ensureFailure("server.spawn_failed")))
        #expect(!DaemonLauncher.isStuckOwnerFailure(ensureFailure("server.different_session")))
    }
}
