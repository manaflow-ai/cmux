@testable import CmuxNextAppHealth
import CmuxNextControl
import CmuxNextWakeupsTestSupport
import Testing

/// App health's session service follows the app's connection: an owner that is connected and answers
/// is serving, whatever an earlier ensure or replace left in the model.
@Suite struct AppHealthConnectionFeedTests {
    nonisolated static let linked = AppHealth().isModelLinked

    /// 2026-11-13, after the self-update to nightly 4354476862201: "Session service isn't responding"
    /// stayed on the sidebar while the owner answered in 13 ms. A start and a progress line with no
    /// end after them (a replace refused after it wrote, an ensure's write seen after it returned)
    /// left a restore that never progressed: stuck two minutes later, with nothing to clear it until
    /// the next launch. The connection coming up, answering, ends it.
    @Test(.enabled(if: linked)) func aConnectedOwnerEndsARestoreNoEnsureEnded() {
        let health = AppHealth(clock: ManualClock())
        health.register(AppHealth.sessionDaemonID, kind: .sessionDaemon, label: "Session service")
        health.register(AppHealth.acpmuxID, kind: .acpmux, label: "Connection to the session service", visible: false)
        health.noteDaemonStarted()
        health.noteDaemonRestoring(pid: nil)
        #expect(health.isTimerArmed, "a restore arms its no-progress bound")

        AppHealthConnectionFeed.apply(.up(pid: 33556), to: health)

        #expect(!health.isTimerArmed, "a serving owner is no restore: nothing left to time")
        #expect(health.headline == nil)
        #expect(!health.holdsReplace, "nothing to protect from a replace")
    }
}
