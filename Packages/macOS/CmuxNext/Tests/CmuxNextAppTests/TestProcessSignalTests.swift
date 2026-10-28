import CmuxNextTestExitTrace
import Darwin
import Testing

/// The test process takes the app's SIGPIPE policy (ChildSignalDefaults.installAppSignalPolicy):
/// a write to a pipe whose reader is gone fails with EPIPE instead of ending every test in the
/// process (an AgentPane shard died on signal 13 with 19 tests never finished, 2026-10-28).
struct TestProcessSignalTests {
    @Test func aWriteToAClosedPipeFailsWithEPIPEAndTheRunGoesOn() {
        var fds: [Int32] = [0, 0]
        #expect(pipe(&fds) == 0)
        close(fds[0])
        defer { close(fds[1]) }
        // Caught when the bundle loads (CmuxNextTestSignalPolicy.c), or by the app's own policy if
        // a ChildSignalDefaults test installed it since: either way not the default action.
        var current = sigaction()
        sigaction(SIGPIPE, nil, &current)
        #expect(unsafeBitCast(current.__sigaction_u, to: Int.self) != 0, "SIGPIPE still has its default action")
        let byte: [UInt8] = [0x2E]
        let written = write(fds[1], byte, 1)
        let failure = errno
        #expect(written == -1)
        #expect(failure == EPIPE)
        // The bundle's handler counts what it caught (and notes the first catches on stderr).
        #expect(cmux_next_test_sigpipes() >= 0)
    }
}
