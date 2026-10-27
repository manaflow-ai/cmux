import Foundation
import Testing
@testable import CmuxNextCloud

@Suite("Cloud Codex broker app adapter", .timeLimit(.minutes(1)))
struct CloudCodexBrokerAdapterTests {
    actor Files {
        var values: [String: [String: Data]] = [:]
        var live = true
        var removals = 0
        var pausedChecks = 0
        var pausedWaiter: CheckedContinuation<Void, Never>?
        func pause() { live = false }
        func waitForTwoPausedChecks() async {
            if pausedChecks >= 2 { return }
            await withCheckedContinuation { pausedWaiter = $0 }
        }
        func isLive() -> Bool {
            if !live {
                pausedChecks += 1
                if pausedChecks >= 2 { pausedWaiter?.resume(); pausedWaiter = nil }
            }
            return live
        }
        func read(_ machine: String, _ path: String) -> Data? { values[machine]?[path] }
        func write(_ machine: String, _ path: String, _ data: Data) { values[machine, default: [:]][path] = data }
        func remove(_ machine: String, _ path: String) { removals += 1; values[machine]?[path] = nil }
        func commit(_ machine: String, _ a: String, _ b: String, _ c: String, _ d: String) {
            values[machine, default: [:]][b] = values[machine]?[a]
            values[machine, default: [:]][d] = values[machine]?[c]
        }
        nonisolated func target(_ machine: String) -> CloudCodexBrokerTarget {
            CloudCodexBrokerTarget(machineID: machine, capability: {
                .init(ownerVM: true, protocolVersion: 1, codexExternalAccessToken: true)
            }, makeDirectory: { _ in }, readFile: { await self.read(machine, $0) },
            writeFile: { path, data, _ in try Task.checkCancellation(); await self.write(machine, path, data) },
            commitFiles: { a, b, c, d in await self.commit(machine, a, b, c, d) },
            removeFile: { try Task.checkCancellation(); await self.remove(machine, $0) },
            isLive: { try Task.checkCancellation(); return await self.isLive() })
        }
    }

    private func fixture(shortGrants: Bool = false) throws -> (URL, CloudCodexBrokerAdapter.Launch) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("codex-adapter-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fake = root.appendingPathComponent("broker.sh")
        let script = #"""
#!/bin/sh
holder="$3"
while IFS= read -r line; do
  id=$(printf '%s' "$line" | sed -E 's/.*"id":([0-9]+).*/\1/')
  if printf '%s' "$line" | grep -q '"method":"login"'; then
    touch "$holder/signed-in"
    echo "{\"id\":$id,\"result\":{\"verificationUrl\":\"https://auth.openai.com/codex/device\",\"userCode\":\"TEST-CODE\"}}"
  elif [ -f "$holder/signed-in" ]; then
    expiry=2147483647; if [ "SHORT_GRANTS" = yes ]; then expiry=$(($(date +%s) + 123)); fi
    echo "{\"id\":$id,\"result\":{\"accessToken\":\"short-access\",\"chatgptAccountId\":\"account\",\"expiresAt\":$expiry}}"
  else
    echo "{\"id\":$id,\"error\":\"codex_auth_unavailable\"}"
  fi
done
"""#.replacingOccurrences(of: "SHORT_GRANTS", with: shortGrants ? "yes" : "no")
        try script.write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake.path)
        return (root, .init(executable: fake, prefix: [], codex: URL(fileURLWithPath: "/bin/false")))
    }

    @Test func homesAreStableAndSeparateForEveryAccountScope() throws {
        let (root, launch) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = Files()
        let adapter = CloudCodexBrokerAdapter(root: root, registry: .init(), currentScope: { nil }, launch: { launch }, target: { _, id in files.target(id) })
        let scopes = [CloudCodexBrokerScope(userID: "user", teamID: nil),
                      .init(userID: "user", teamID: ""), .init(userID: "user", teamID: "a/b"),
                      .init(userID: "user/a", teamID: "b"), .init(userID: "other", teamID: nil)]
        #expect(Set(scopes.map { adapter.home(for: $0) }).count == scopes.count)
        #expect(adapter.home(for: scopes[0]) == adapter.home(for: scopes[0]))
        #expect(adapter.home(for: scopes[0]).lastPathComponent.count == 64)
    }

    @Test func cancelledFirstLoginPreservesVMModeAndStopsRegistration() async throws {
        let (root, launch) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = Files()
        let scope = CloudCodexBrokerScope(userID: "user", teamID: nil)
        let registry = CloudCodexBrokerRegistry()
        let adapter = CloudCodexBrokerAdapter(root: root, registry: registry, currentScope: { scope }, launch: { launch }, target: { _, id in files.target(id) })
        await files.write("vm", CloudCodexBroker.modePath, Data("team\n".utf8))
        await #expect(throws: CloudCodexBrokerError.cancelled) {
            try await adapter.run(machineID: "vm", scope: scope, confirmed: true) { _ in false }
        }
        #expect(await files.read("vm", CloudCodexBroker.modePath) == Data("team\n".utf8))
        #expect(await files.read("vm", CloudCodexBroker.accessPath) == nil)
        let broker = try #require(await registry.existing(for: scope))
        #expect(await broker.registeredMachineIDs().isEmpty)
        await adapter.shutdown()
    }

    @Test func reusesLoginAcrossVMsAndAppRestartAndCleansDeliveredFiles() async throws {
        let (root, launch) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = Files()
        let scope = CloudCodexBrokerScope(userID: "user", teamID: "team")
        var prompts = 0
        let adapter = CloudCodexBrokerAdapter(root: root, registry: .init(), currentScope: { scope }, launch: { launch }, target: { _, id in files.target(id) })
        let present: @MainActor @Sendable (CloudCodexLoginPrompt) async -> Bool = { prompt in
            #expect(prompt.userCode == "TEST-CODE"); prompts += 1; return true
        }
        try await adapter.run(machineID: "one", scope: scope, confirmed: true, presentDeviceCode: present)
        try await adapter.run(machineID: "two", scope: scope, confirmed: true, presentDeviceCode: present)
        #expect(prompts == 1)
        #expect(await files.read("one", CloudCodexBroker.accessPath) != nil)
        #expect(await files.read("two", CloudCodexBroker.accessPath) != nil)
        await adapter.shutdown()
        #expect(await files.read("one", CloudCodexBroker.accessPath) == nil)
        #expect(await files.read("two", CloudCodexBroker.accessPath) == nil)
        let restarted = CloudCodexBrokerAdapter(root: root, registry: .init(), currentScope: { scope }, launch: { launch }, target: { _, id in files.target(id) })
        try await restarted.run(machineID: "three", scope: scope, confirmed: true, presentDeviceCode: present)
        #expect(prompts == 1)
        await restarted.shutdown()
    }

    @Test func taskCancellationRevokesPreviouslyDeliveredAccessWithUncancelledTransport() async throws {
        let (root, launch) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = Files()
        let scope = CloudCodexBrokerScope(userID: "user", teamID: nil)
        let gate = CloudCodexBrokerTests.Gate()
        let adapter = CloudCodexBrokerAdapter(root: root, registry: .init(), currentScope: { scope }, launch: { launch }, target: { _, id in files.target(id) })
        try await adapter.run(machineID: "vm", scope: scope, confirmed: true) { _ in true }
        #expect(await files.read("vm", CloudCodexBroker.accessPath) != nil)
        // Make the fake provider request login again while a previous grant remains delivered.
        try FileManager.default.removeItem(at: adapter.home(for: scope).appendingPathComponent("signed-in"))
        let pending = Task {
            try await adapter.run(machineID: "vm", scope: scope, confirmed: true, forceRefresh: true) { _ in
                await gate.pause(); return true
            }
        }
        await gate.entered()
        pending.cancel()
        await gate.open()
        await #expect(throws: (any Error).self) { try await pending.value }
        #expect(await files.read("vm", CloudCodexBroker.accessPath) == nil)
        #expect(adapter.pendingCleanup.isEmpty)
        await adapter.shutdown()
    }

    @Test func pausedRenewalDoesNotIssueCleanupFileRequests() async throws {
        let (root, launch) = try fixture(shortGrants: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = Files()
        let scope = CloudCodexBrokerScope(userID: "user", teamID: nil)
        let adapter = CloudCodexBrokerAdapter(root: root, registry: .init(), currentScope: { scope }, launch: { launch }, target: { _, id in files.target(id) })
        try await adapter.run(machineID: "vm", scope: scope, confirmed: true) { _ in true }
        let before = await files.removals
        await files.pause()
        // A second scheduled probe proves the preceding renewal completed.
        await files.waitForTwoPausedChecks()
        #expect(await files.removals == before)
        await adapter.shutdown()
        #expect(adapter.pendingCleanup.contains("vm"))
    }

    @Test func scopeSwitchCancelsPendingPromptWithoutDelivery() async throws {
        let (root, launch) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = Files()
        let original = CloudCodexBrokerScope(userID: "user", teamID: nil)
        var current: CloudCodexBrokerScope? = original
        let gate = CloudCodexBrokerTests.Gate()
        let adapter = CloudCodexBrokerAdapter(root: root, registry: .init(), currentScope: { current }, launch: { launch }, target: { _, id in files.target(id) })
        let pending = Task { try await adapter.run(machineID: "vm", scope: original, confirmed: true) { _ in await gate.pause(); return true } }
        await gate.entered()
        current = .init(userID: "other", teamID: nil)
        await adapter.scopeDidChange()
        await gate.open()
        await #expect(throws: (any Error).self) { try await pending.value }
        #expect(await files.read("vm", CloudCodexBroker.accessPath) == nil)
        await adapter.shutdown()
    }

    @Test func policyFenceStopsPendingDeliveryAndReenableReusesHolder() async throws {
        let (root, launch) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = Files()
        let scope = CloudCodexBrokerScope(userID: "user", teamID: nil)
        let gate = CloudCodexBrokerTests.Gate()
        let adapter = CloudCodexBrokerAdapter(root: root, registry: .init(), currentScope: { scope }, launch: { launch }, target: { _, id in files.target(id) })
        var prompts = 0
        let pending = Task {
            try await adapter.run(machineID: "vm", scope: scope, confirmed: true) { _ in
                prompts += 1
                await gate.pause()
                return true
            }
        }
        await gate.entered()
        adapter.setAvailable(false)
        await gate.open()
        await #expect(throws: (any Error).self) { try await pending.value }
        #expect(await files.read("vm", CloudCodexBroker.accessPath) == nil)

        adapter.setAvailable(true)
        try await adapter.run(machineID: "vm", scope: scope, confirmed: true) { _ in
            prompts += 1
            return true
        }
        #expect(prompts == 1)
        #expect(await files.read("vm", CloudCodexBroker.accessPath) != nil)
        await adapter.shutdown()
    }
}
