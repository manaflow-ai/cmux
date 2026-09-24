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
        let (computers, host, _) = try await makeRuntimeInDirectory()
        return (computers, host)
    }

    private func makeRuntimeInDirectory() async throws -> (MobileSSHComputers, SSHHostRecord, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-ssh-auto-\(UUID().uuidString)")
        let computers = MobileSSHComputers(directory: dir)
        // No key: a connect attempt fails immediately without any network.
        let host = SSHHostRecord(name: "Keyless", endpoint: SSHEndpoint(host: "127.0.0.1", port: 1, username: "nobody"))
        try await computers.saveHost(host)
        return (computers, host, dir)
    }

    private static let serverKey = SSHHostKey(openSSHString: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl")

    /// Asks `prompt` the way the host-key verifier does and answers it as the
    /// user would from the prompt sheet.
    private func decline(_ prompt: MobileSSHPrompt, on computers: MobileSSHComputers) async {
        let asked = Task { await computers.ask(prompt) }
        while computers.prompts.isEmpty { await Task.yield() }
        computers.answer(prompt, with: .cancel)
        #expect(await asked.value == .cancel)
    }

    /// Waits for the background write of the pause flag to reach disk.
    private func persistedPause(_ computers: MobileSSHComputers, hostID: UUID, equals expected: Bool) async -> Bool {
        for _ in 0..<1_000 {
            if await computers.hostStore.host(id: hostID)?.isAutoConnectPaused == expected { return true }
            await Task.yield()
        }
        return false
    }

    /// A fresh runtime over the same directory, like the next app launch.
    private func relaunch(_ dir: URL) async -> MobileSSHComputers {
        let computers = MobileSSHComputers(directory: dir)
        await computers.reload()
        return computers
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

    @Test func decliningANewServerKeyPausesAutoConnectAcrossRelaunch() async throws {
        let (computers, host, dir) = try await makeRuntimeInDirectory()
        await decline(.trustNewHostKey(host: host, key: Self.serverKey), on: computers)
        #expect(!computers.canAutoConnect(hostID: host.id))
        #expect(computers.autoConnect(hostID: host.id) == nil)
        #expect(await persistedPause(computers, hostID: host.id, equals: true))

        let relaunched = await relaunch(dir)
        #expect(relaunched.isAutoConnectPaused(hostID: host.id))
        #expect(!relaunched.canAutoConnect(hostID: host.id), "the next launch must not ask again on its own")
        #expect(relaunched.autoConnect(hostID: host.id) == nil)
    }

    @Test func decliningAChangedServerKeyPausesAutoConnect() async throws {
        let (computers, host, _) = try await makeRuntimeInDirectory()
        let other = SSHHostKey(openSSHString: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIB0cWb1VbW7fS0dR1xk0y1P0l5m3oZr6t0n3V2Jd8K4q")
        await decline(.hostKeyChanged(host: host, pinned: Self.serverKey, presented: other), on: computers)
        #expect(!computers.canAutoConnect(hostID: host.id))
        #expect(await persistedPause(computers, hostID: host.id, equals: true))
    }

    @Test func trustingDoesNotPause() async throws {
        let (computers, host, _) = try await makeRuntimeInDirectory()
        let prompt = MobileSSHPrompt.trustNewHostKey(host: host, key: Self.serverKey)
        let asked = Task { await computers.ask(prompt) }
        while computers.prompts.isEmpty { await Task.yield() }
        computers.answer(prompt, with: .trust)
        #expect(await asked.value == .trust)
        #expect(!computers.isAutoConnectPaused(hostID: host.id))
        #expect(computers.canAutoConnect(hostID: host.id))
    }

    @Test func explicitOpenResumesAutoConnectPersistently() async throws {
        let (computers, host, dir) = try await makeRuntimeInDirectory()
        await decline(.trustNewHostKey(host: host, key: Self.serverKey), on: computers)
        #expect(await persistedPause(computers, hostID: host.id, equals: true))
        // Pull-to-refresh, choosing the host, or tapping it in Computers.
        await computers.open(hostID: host.id)
        #expect(!computers.isAutoConnectPaused(hostID: host.id))
        #expect(await persistedPause(computers, hostID: host.id, equals: false))
        let relaunched = await relaunch(dir)
        #expect(relaunched.canAutoConnect(hostID: host.id))
    }

    @Test func aDeclinedJumpHostPausesTheHostsBehindIt() async throws {
        let (computers, jump, _) = try await makeRuntimeInDirectory()
        let target = SSHHostRecord(
            name: "Behind Jump",
            endpoint: SSHEndpoint(host: "10.0.0.2", port: 1, username: "nobody"),
            jumpHostID: jump.id
        )
        try await computers.saveHost(target)
        #expect(computers.canAutoConnect(hostID: target.id))
        await decline(.trustNewHostKey(host: jump, key: Self.serverKey), on: computers)
        #expect(!computers.canAutoConnect(hostID: target.id))
        await computers.open(hostID: target.id)
        #expect(!computers.isAutoConnectPaused(hostID: jump.id), "opening the target asks about its jump host again")
    }

    @Test func hostsSavedBeforeThePauseFlagStillDecode() throws {
        let json = """
        [{"id":"8C4E2F6A-3B1D-4E5F-9A7B-1C2D3E4F5A6B","name":"Old","endpoint":{"host":"example.com","port":22,"username":"me"},"idleClose":"oneDay","createdAt":0}]
        """
        let hosts = try JSONDecoder().decode([SSHHostRecord].self, from: Data(json.utf8))
        #expect(hosts.count == 1)
        #expect(hosts[0].isAutoConnectPaused == false)
    }
}
