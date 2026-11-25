@testable import CmuxNextDaemon
@testable import CmuxNextDaemonService
import Testing

/// The launch handoff's marker (`DaemonService.replacingDaemon`) that hides "Update ready for cmux-tui"
/// for the daemon being replaced (ask-154758ed56): it names one daemon run by its generation, and a
/// failed handoff clears it, so a daemon that stays gets its notice back.
@MainActor
@Suite struct DaemonReplacementMarkerTests {
    @Test func aFailedHandoffClearsTheMarkerAndAnotherRunNeverMatches() {
        let daemon = DaemonService()
        let old: DaemonGeneration = "gen-old"
        daemon.noteReplacing(old)
        #expect(daemon.replacingDaemon == old)

        daemon.noteReplacementFailed("gen-other")
        #expect(daemon.replacingDaemon == old, "another run's failure leaves this run's marker")

        daemon.noteReplacementFailed(old)
        #expect(daemon.replacingDaemon == nil, "the daemon stays: its update notice shows again")
    }
}
