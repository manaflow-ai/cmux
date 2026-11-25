import CmuxNextTestExitTrace
import Darwin
import Testing

/// The test process takes the app's SIGPIPE policy (ChildSignalDefaults.installAppSignalPolicy):
/// a write to a pipe whose reader is gone fails with EPIPE instead of ending every test in the
/// process (an AgentPane shard died on signal 13 with 19 tests never finished, 2026-10-28).
///
/// SIGPIPE's disposition is process-wide and other suites change it while they run
/// (ChiefAdoptionLiveWriterTests sets SIG_IGN), so these tests never read or send it live: the
/// install is checked when the bundle loads, before any test, and the handler is called directly.
struct TestProcessSignalTests {
    @Test func theBundleCatchesSIGPIPEFromTheMomentItLoads() {
        #expect(cmux_next_test_signal_policy_installed_at_load() == 1)
    }

    @Test func theInstalledDispositionIsTheBundlesHandlerNotIgnoreOrDefault() {
        var action = sigaction()
        cmux_next_test_signal_policy_action(&action)
        #expect(cmux_next_test_signal_policy_is_handler(&action) == 1)
        // SIG_DFL is the handler value 0 and SIG_IGN is 1 (<sys/signal.h>).
        let handler = unsafeBitCast(action.__sigaction_u, to: Int.self)
        #expect(handler != 0 && handler != 1)
        #expect(action.sa_flags & SA_RESTART != 0)
        var ignore = sigaction()
        ignore.__sigaction_u.__sa_handler = SIG_IGN
        #expect(cmux_next_test_signal_policy_is_handler(&ignore) == 0)
    }

    @Test func aCaughtSIGPIPEIsCountedAndLeavesErrnoAsItWas() {
        let before = cmux_next_test_sigpipes()
        errno = EPIPE
        cmux_next_test_sigpipe_handle()
        let after = errno
        #expect(after == EPIPE)
        #expect(cmux_next_test_sigpipes() >= before + 1)
    }
}
