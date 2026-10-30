import Foundation
import Testing
@testable import CmuxNextAgentPane

/// A socket path that does not fit a Unix socket address (`sun_path`, a long TMPDIR) is refused
/// before it reaches the Network framework, which traps on one. The page's `_acpmux/status` read
/// (``AgentPaneTransport/analyze(_:_:socket:ids:)``) passed such a path and crashed the whole
/// process (issue #28492).
struct AcpmuxStatusClientSocketPathTests {
    @Test func aSocketPathPastTheUnixLimitIsRefusedNotATrap() async {
        let path = "/" + String(repeating: "p", count: AcpmuxEnvironment.maxSocketPathBytes) + "/acpmux.sock"
        await #expect(throws: AcpmuxStatusClient.Failure.self) {
            _ = try await AcpmuxStatusClient.call(socketPath: path, method: "_acpmux/status", deadline: .seconds(2))
        }
    }
}
