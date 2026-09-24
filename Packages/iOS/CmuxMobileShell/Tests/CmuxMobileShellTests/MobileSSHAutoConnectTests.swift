@testable import CmuxMobileShell
import CmuxMobileSSH
import Foundation
import Testing

/// An SSH computer the user is looking at reconnects on its own like a Mac,
/// but never loops: failures keep Retry, and hosts the user disconnected or
/// declined stay manual until opened again.
@MainActor
@Suite struct MobileSSHAutoConnectTests {
    private func makeRuntime() async throws -> (MobileSSHComputers, SSHHostRecord) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-ssh-auto-\(UUID().uuidString)")
        let computers = MobileSSHComputers(directory: dir)
        // No key: a connect attempt fails immediately without any network.
        let host = SSHHostRecord(name: "Keyless", endpoint: SSHEndpoint(host: "127.0.0.1", port: 1, username: "nobody"))
        try await computers.saveHost(host)
        return (computers, host)
    }

    @Test func idleSavedHostIsEligibleUnknownHostIsNot() async throws {
        let (computers, host) = try await makeRuntime()
        #expect(computers.canAutoConnect(hostID: host.id))
        #expect(!computers.canAutoConnect(hostID: UUID()))
        #expect(computers.autoConnect(hostID: UUID()) == nil)
    }

    @Test func autoConnectRunsOnceAndAFailureKeepsRetry() async throws {
        let (computers, host) = try await makeRuntime()
        let task = try #require(computers.autoConnect(hostID: host.id))
        // A second trigger while the first is in flight is a no-op.
        #expect(computers.autoConnect(hostID: host.id) == nil)
        await task.value
        guard case .failed = computers.statusByHost[host.id] else {
            Issue.record("expected failed, got \(String(describing: computers.statusByHost[host.id]))")
            return
        }
        #expect(!computers.canAutoConnect(hostID: host.id), "a failed host waits for Retry")
        #expect(computers.autoConnect(hostID: host.id) == nil)
    }

    @Test func userDisconnectStaysManualUntilOpened() async throws {
        let (computers, host) = try await makeRuntime()
        await computers.disconnect(hostID: host.id)
        #expect(computers.statusByHost[host.id] == .idle)
        #expect(!computers.canAutoConnect(hostID: host.id))
        // An explicit open lifts the suppression (it fails here: no key).
        await computers.open(hostID: host.id)
        await computers.disconnect(hostID: host.id)
        #expect(!computers.canAutoConnect(hostID: host.id))
    }
}
