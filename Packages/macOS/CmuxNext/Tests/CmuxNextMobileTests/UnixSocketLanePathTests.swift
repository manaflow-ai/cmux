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
        let result = await #expect(processExitsWith: .success, observing: [\.standardErrorContent]) {
            ChildCrashFrames.printOnFatalSignal()
            let path = "/" + String(repeating: "p", count: 200) + "/daemon.sock"
            if (try? await UnixSocketLane.connect(path: path, deadline: .seconds(2))) != nil { exit(EXIT_FAILURE) }
        }
        ChildCrashFrames.record(result)
    }
}
