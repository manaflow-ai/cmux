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
        let result = await #expect(processExitsWith: .success, observing: [\.standardErrorContent]) {
            ChildCrashFrames.printOnFatalSignal()
            let path = "/" + String(repeating: "p", count: 200) + "/acpmux.sock"
            // Any error is a refusal; only an answer (or a trap) is wrong. The guard's exact refusal: UnixSocketEndpointTests.
            if (try? await AcpmuxStatusClient.call(socketPath: path, method: "_acpmux/status", deadline: .seconds(2))) != nil {
                exit(EXIT_FAILURE)
            }
        }
        ChildCrashFrames.record(result)
    }
}
