import CmuxNextTestSupport
import Foundation
import Testing
@testable import CmuxNextMobile

/// A daemon socket path that does not fit a Unix socket address (`sun_path`) is refused before it
/// reaches the Network framework, which traps on one (issue #28492). The path comes from the
/// caller (the daemon's socket under a long home or TMPDIR). The connect runs in an exit test's
/// child, so a trap fails this test with its frames (``ChildCrashFrames``) and no other test.
struct UnixSocketLanePathTests {
    @Test func aSocketPathPastTheUnixLimitIsRefusedNotATrap() async {
        await #expect(processExitsWith: .success) {
            ChildCrashFrames.printOnFatalSignal("unix-lane-sun-path")
            let path = "/" + String(repeating: "p", count: 200) + "/daemon.sock"
            do {
                _ = try await UnixSocketLane.connect(path: path, deadline: .seconds(2))
                ChildCrashFrames.fail("the connect succeeded")
            } catch {
                // The guard's own refusal, before any connection: not a caught trap, not a timeout.
                guard (error as? UnixSocketLane.Failure) == .pathTooLong(path: path) else { ChildCrashFrames.fail("refused with \(error)") }
            }
        }
        ChildCrashFrames.record("unix-lane-sun-path")
    }
}
