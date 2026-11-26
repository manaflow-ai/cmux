import Foundation
import Testing
@testable import CmuxIrohTransport

@Suite("Iroh persistence lifecycle races")
struct CmxIrohPersistenceLifecycleRaceTests {
    @Test("sign-out fences a suspended relay credential write")
    func brokerRepositoryDeactivationFencesSuspendedWrite() async throws {
        let suiteName = "CmxIrohPersistenceLifecycleRaceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = TestControllableSecureCredentialStore()
        let repository = CmxIrohBrokerCredentialRepository(
            secureStore: store,
            installState: CmxIrohUserDefaultsInstallStateStore(defaults: defaults)
        )
        let fixture = try ClientRuntimeTestFixture()
        let binding = CmxIrohBrokerBindingMetadata(binding: fixture.binding)
        let relayFleet = fixture.configuration.managedRelayURLs
        try await repository.saveBinding(binding, accountID: "account-a")
        await store.suspendNextWrite()
        let save = Task {
            try await repository.saveRelayCredential(
                fixture.relayResponse(),
                accountID: "account-a",
                binding: binding,
                expectedRelayFleet: relayFleet,
                now: fixture.now
            )
        }
        await store.waitUntilWriteIsSuspended()
        await store.suspendNextDeleteAll()

        let deactivate = Task { try await repository.deactivate() }
        #expect(
            await waitsForLifecycleCancellation {
                _ = try await repository.loadBinding(
                    accountID: "account-a",
                    appInstanceID: binding.appInstanceID
                )
            }
        )
        await store.resumeSuspendedWrite()
        await #expect(throws: CancellationError.self) { try await save.value }
        await store.waitUntilDeleteAllIsSuspended()
        await store.resumeSuspendedDeleteAll()
        try await deactivate.value

        #expect(await store.recordCount() == 0)
        #expect(await store.deleteAllCount() == 2)
    }

    @Test("sign-out fences a suspended host-policy write")
    func hostPolicyDeactivationFencesSuspendedWrite() async throws {
        let fixture = try HostPolicyCacheTestFixture()
        let expectation = try fixture.expectation()
        let store = TestControllableSecureCredentialStore()
        let cache = CmxIrohHostPolicyCache(secureStore: store)
        await store.suspendNextWrite()
        let save = Task {
            try await cache.save(
                fixture.policy(),
                for: expectation,
                now: fixture.now
            )
        }
        await store.waitUntilWriteIsSuspended()
        await store.suspendNextDeleteAll()
        let now = fixture.now

        let deactivate = Task { try await cache.deactivate() }
        #expect(
            await waitsForLifecycleCancellation {
                _ = try await cache.load(for: expectation, now: now)
            }
        )
        await store.resumeSuspendedWrite()
        await #expect(throws: CancellationError.self) { try await save.value }
        await store.waitUntilDeleteAllIsSuspended()
        await store.resumeSuspendedDeleteAll()
        try await deactivate.value

        #expect(await store.recordCount() == 0)
        #expect(await store.deleteAllCount() == 1)
    }
}

private func waitsForLifecycleCancellation(
    _ operation: @escaping @Sendable () async throws -> Void
) async -> Bool {
    await withTaskGroup(of: Bool.self) { group in
        group.addTask {
            while !Task.isCancelled {
                do {
                    try await operation()
                } catch is CancellationError {
                    return true
                } catch {
                    return false
                }
                await Task.yield()
            }
            return false
        }
        group.addTask {
            do {
                try await ContinuousClock().sleep(for: .seconds(1))
            } catch {
                return false
            }
            return false
        }
        let result = await group.next() ?? false
        group.cancelAll()
        return result
    }
}
