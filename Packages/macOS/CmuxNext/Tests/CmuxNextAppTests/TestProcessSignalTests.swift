import CmuxNextTestExitTrace
import Darwin
import Testing

/// The test process takes the app's SIGPIPE policy (ChildSignalDefaults.installAppSignalPolicy):
/// a write to a pipe whose reader is gone fails with EPIPE instead of ending every test in the
/// process (an AgentPane shard died on signal 13 with 19 tests never finished, 2026-10-28).
struct TestProcessSignalTests {
    @Test func aWriteToAClosedPipeFailsWithEPIPEAndTheRunGoesOn() {
        // The bundle's handler was in place once it loaded (CmuxNextTestSignalPolicy.c).
        #expect(cmux_next_test_signal_policy_installed_at_load() == 1)
        // Another suite may have changed SIGPIPE since (ChiefAdoptionLiveWriterTests sets SIG_IGN), so
        // take the bundle's handler again: then this write's catch is the bundle's to count.
        cmux_next_test_signal_policy_install()
        #expect(cmux_next_test_sigpipe_handler_is_current() == 1, "SIGPIPE's handler is SIG_DFL, SIG_IGN or another")
        var fds: [Int32] = [0, 0]
        #expect(pipe(&fds) == 0)
        close(fds[0])
        defer { close(fds[1]) }
        let before = cmux_next_test_sigpipes()
        let byte: [UInt8] = [0x2E]
        let written = write(fds[1], byte, 1)
        let failure = errno
        #expect(written == -1)
        #expect(failure == EPIPE)
        // At least this write's catch (another test's write in the same moment could add one more).
        #expect(cmux_next_test_sigpipes() >= before + 1)
    }
}
