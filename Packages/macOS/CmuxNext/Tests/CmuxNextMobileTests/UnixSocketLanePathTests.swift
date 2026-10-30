import Foundation
import Testing
@testable import CmuxNextMobile

/// A daemon socket path that does not fit a Unix socket address (`sun_path`) is refused before it
/// reaches the Network framework, which traps on one (issue #28492). The path comes from the
/// caller (the daemon's socket under a long home or TMPDIR).
struct UnixSocketLanePathTests {
    @Test func aSocketPathPastTheUnixLimitIsRefusedNotATrap() async {
        let path = "/" + String(repeating: "p", count: 200) + "/daemon.sock"
        await #expect(throws: UnixSocketLane.Failure.pathTooLong(path: path)) {
            _ = try await UnixSocketLane.connect(path: path, deadline: .seconds(2))
        }
    }
}
