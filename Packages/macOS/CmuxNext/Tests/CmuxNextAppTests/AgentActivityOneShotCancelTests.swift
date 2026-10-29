import CmuxNextAgentActivity
import Darwin
import Foundation
import Testing

/// A cancelled `AgentActivityLineConnection.oneShot` (a Stats tab closed mid-scan, a cua call
/// whose task went away) returns at once with `CancellationError`; it used to wait out its whole
/// deadline and then report `timedOut`, which the Stats page reads as "not running".
struct AgentActivityOneShotCancelTests {
    @Test func cancellingReturnsBeforeTheDeadline() async throws {
        let server = try SilentServer()
        defer { server.close() }
        let call = Task {
            try await AgentActivityLineConnection.oneShot(path: server.path, send: Data("{}\n".utf8), deadline: .seconds(20))
        }
        try await Task.sleep(for: .milliseconds(200))
        // Timed from the cancel, not from before the task was made: the task's start and the 200 ms sleep
        // are not the cancel's cost, and in a starved full parallel run (11.8 s measured from the start)
        // they wait seconds for the cooperative pool.
        let clock = ContinuousClock()
        let cancelled = clock.now
        call.cancel()
        await #expect(throws: CancellationError.self) { try await call.value }
        let elapsed = clock.now - cancelled
        #expect(elapsed < .seconds(5), "a cancelled call returned \(elapsed) after its cancel")
    }

    @Test func alreadyCancelledReturnsAtOnce() async throws {
        let server = try SilentServer()
        defer { server.close() }
        let call = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await AgentActivityLineConnection.oneShot(path: server.path, send: Data("{}\n".utf8), deadline: .seconds(20))
        }
        await #expect(throws: CancellationError.self) { try await call.value }
    }
}

/// A unix socket that accepts connections (through its backlog) and never answers.
private final class SilentServer {
    let path: String
    private let descriptor: Int32

    init() throws {
        path = NSTemporaryDirectory() + "oneshot-\(UUID().uuidString.prefix(8)).sock"
        descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: path.utf8.prefix(buffer.count - 1))
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard descriptor >= 0, bound == 0, listen(descriptor, 4) == 0 else {
            throw POSIXError(.EADDRNOTAVAIL)
        }
    }

    func close() {
        Darwin.close(descriptor)
        unlink(path)
    }
}
