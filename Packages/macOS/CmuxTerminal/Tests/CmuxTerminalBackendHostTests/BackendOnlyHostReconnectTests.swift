import CmuxTerminalBackend
@testable import CmuxTerminalBackendHost
import Foundation
import Testing

@Suite("Backend-only host reconnect lifecycle")
@MainActor
struct BackendOnlyHostReconnectTests {
    @Test("failed v2 hydration invalidates before the bounded retry")
    func failedHydrationRetriesWithFreshConnectionGeneration() async throws {
        let topology = try HostProjectionFixture.topology()
        let first = try HostProjectionFixture.connection(number: 1, topology: topology)
        let second = try HostProjectionFixture.connection(number: 2, topology: topology)
        let firstRPC = HostProjectionFakeRPC(
            snapshot: first.initialSnapshot,
            processInstanceID: first.processInstanceID
        )
        let secondRPC = HostProjectionFakeRPC(
            snapshot: second.initialSnapshot,
            processInstanceID: second.processInstanceID
        )
        await firstRPC.failNextClaim()
        let controller = HostProjectionFakeController([
            .init(connection: first, rpc: firstRPC),
            .init(connection: second, rpc: secondRPC),
        ])
        let model = BackendOnlyHostModel(
            controller: controller,
            defaults: isolatedDefaults(),
            logicalPresentationID: HostProjectionFixture.uuid(910),
            maximumConnectionAttempts: 2,
            runtimeFactory: HostProjectionRuntimeFactory().makeRuntime
        )

        model.start()
        await model.awaitCurrentConnectionCycle()

        #expect(model.phase == .ready)
        #expect(model.runtimeSnapshot?.fence.connectionGeneration == 2)
        #expect(await controller.invalidationCount == 1)
        #expect(await controller.connectAttemptCount == 2)
    }

    @Test("automatic reconnect attempts stop at the configured bound")
    func automaticReconnectAttemptsAreBounded() async {
        let controller = HostProjectionFakeController([])
        let model = BackendOnlyHostModel(
            controller: controller,
            defaults: isolatedDefaults(),
            logicalPresentationID: HostProjectionFixture.uuid(911),
            maximumConnectionAttempts: 3,
            runtimeFactory: HostProjectionRuntimeFactory().makeRuntime
        )

        model.start()
        await model.awaitCurrentConnectionCycle()

        #expect(model.phase == .unavailable)
        #expect(await controller.connectAttemptCount == 3)
    }

    private func isolatedDefaults() -> UserDefaults {
        let suiteName = "BackendOnlyHostReconnectTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
