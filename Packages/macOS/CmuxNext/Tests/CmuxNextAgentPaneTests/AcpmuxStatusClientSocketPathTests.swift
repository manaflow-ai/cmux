import CmuxNextTestSupport
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// A socket path that does not fit a Unix socket address (`sun_path`, a long TMPDIR) is refused
/// before it reaches the Network framework, which traps on one. The page's `_acpmux/status` read
/// (``AgentPaneTransport/analyze(_:_:socket:ids:)``) passed such a path and crashed the whole
/// process (issue #28492). The read runs in an exit test's child, so a trap fails this test with
/// its frames (``ChildCrashFrames``) and no other test.
struct AcpmuxStatusClientSocketPathTests {
    @Test func aSocketPathPastTheUnixLimitIsRefusedNotATrap() async {
        await #expect(processExitsWith: .success) {
            ChildCrashFrames.printOnFatalSignal("acpmux-status-sun-path")
            let path = "/" + String(repeating: "p", count: 200) + "/acpmux.sock"
            do {
                _ = try await AcpmuxStatusClient.call(socketPath: path, method: "_acpmux/status", deadline: .seconds(2))
                ChildCrashFrames.fail("the call answered")
            } catch {
                // The guard's own refusal, before any connection: not a caught trap, not another failure.
                guard (error as? AcpmuxStatusClient.Failure) == .socketPathTooLong(path) else { ChildCrashFrames.fail("refused with \(error)") }
            }
        }
        ChildCrashFrames.record("acpmux-status-sun-path")
    }
}
