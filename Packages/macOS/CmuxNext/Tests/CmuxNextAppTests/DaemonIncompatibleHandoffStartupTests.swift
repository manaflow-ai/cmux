@testable import CmuxNextDaemonService
import CmuxNextDaemon
import Testing

/// An incompatible owner can be reached after the first startup deadline already marked the
/// service unavailable. The handoff to the bundled build must give the successor a fresh
/// `.connecting` window, or the re-armed deadline sees a non-connecting state and leaves the
/// stale failure on screen while the successor starts.
@Suite struct DaemonIncompatibleHandoffStartupTests {
    @Test @MainActor func aHandoffAfterTheDeadlineShowsConnectingAgain() {
        let daemon = DaemonService()
        daemon.noteStartupFailure(.binaryNotFound(searched: ["/usr/bin/false"]))
        #expect(daemon.startup.isUnavailable)

        daemon.noteIncompatibleOwnerHandoff()

        #expect(daemon.startup == .connecting)
        #expect(daemon.lastStartupError == nil)
    }
}
