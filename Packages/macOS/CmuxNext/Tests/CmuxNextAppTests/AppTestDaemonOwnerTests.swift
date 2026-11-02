@testable import CmuxNextAgentPane
@testable import CmuxNextDaemon
import Darwin
import Foundation
import Testing

@Suite(.serialized)
struct AppTestDaemonOwnerTests {
    private struct HandshakeFailed: Error {}

    private func withChild(_ body: (DaemonEndpoint, AcpmuxDaemonStop.Daemon) async throws -> Void) async throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["3600"]
        child.standardInput = FileHandle.nullDevice
        try child.run()
        guard let identity = AcpmuxDaemonStop.kernelProcess(pid: child.processIdentifier) else {
            child.terminate()
            _ = await ProcessExit.exitEvent(pid: child.processIdentifier, within: .seconds(5), clock: ContinuousClock())
            Issue.record("could not read this test child's kernel identity")
            return
        }
        let endpoint = DaemonEndpoint(socketPath: "/unused", pid: identity.pid)
        let result: Result<Void, any Error>
        do { result = .success(try await body(endpoint, identity)) }
        catch { result = .failure(error) }
        // task-owner: joined child cleanup survives cancellation of the test task.
        let exited = await Task {
            await AppTestDaemonOwner.stop(identity, grace: .seconds(1))
        }.value
        #expect(exited)
        try result.get()
    }

    @Test func aFailedHandshakeStillStopsTheRecordedProcess() async throws {
        try await withChild { endpoint, identity in
            let exited = await AppTestDaemonOwner.reap(endpoint, process: identity, grace: .seconds(1)) {
                throw HandshakeFailed()
            }
            #expect(exited)
        }
    }

    @Test func anUnverifiedLiveProcessIsLeftAloneAndCleanupRemainsIncomplete() async throws {
        try await withChild { endpoint, identity in
            let exited = await AppTestDaemonOwner.reap(endpoint, process: nil) {
                Issue.record("unverified endpoint must not receive a graceful shutdown")
                return true
            }
            #expect(!exited)
            #expect(AcpmuxDaemonStop.kernelProcess(pid: identity.pid) == identity)
        }
    }


    @Test func anUnreadableIdentityDoesNotClaimAStillRunningDaemonExited() async throws {
        try await withChild { endpoint, identity in
            let exited = await AppTestDaemonOwner.waitForRecordedExit(pid: identity.pid, process: identity,
                                                                       timeout: .milliseconds(50), currentProcess: { _ in nil })
            #expect(!exited, "an unreadable identity must keep waiting")
        }
    }

    @Test func aReusedPidDoesNotSignalTheReplacement() async throws {
        try await withChild { endpoint, identity in
            var previous = identity
            previous.token.val.7 &+= 1
            let exited = await AppTestDaemonOwner.reap(endpoint, process: previous) { throw HandshakeFailed() }
            #expect(exited, "the recorded process is gone")
            #expect(AcpmuxDaemonStop.kernelProcess(pid: identity.pid) == identity,
                    "the replacement process must stay alive")
        }
    }
}
