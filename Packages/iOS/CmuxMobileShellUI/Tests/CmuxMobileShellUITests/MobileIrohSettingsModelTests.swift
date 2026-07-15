#if os(iOS)
import CMUXMobileCore
import Testing

@testable import CmuxMobileShellUI

@MainActor
@Suite
struct MobileIrohSettingsModelTests {
    @Test func failedCustomRelaySavePreservesSnapshot() async {
        let initial = snapshot(sequence: 9)
        let controller = MobileIrohSettingsControllerDouble(snapshot: initial)
        controller.upsertError = MobileIrohSettingsTestFailure.rejected
        let model = MobileIrohSettingsModel(controller: controller)
        let observation = Task { await model.observe() }
        await waitUntil { model.snapshot == initial }
        observation.cancel()
        await observation.value

        let saved = await model.upsertCustomRelay(
            CmxIrohCustomRelayDraft(
                displayName: "Relay",
                provider: "Self-hosted",
                region: "Home",
                url: "https://relay.example.test",
                authMode: .none
            ),
            deviceSecret: nil
        )

        #expect(!saved)
        #expect(model.snapshot == initial)
        #expect(model.showsSaveError)
    }

    @Test func failedLocalFollowUpReconcilesToCommittedAccountSnapshot() async {
        let initial = snapshot(sequence: 9)
        let committed = snapshot(sequence: 10)
        let controller = MobileIrohSettingsControllerDouble(snapshot: initial)
        controller.snapshotAfterUpsertError = committed
        controller.upsertError = MobileIrohSettingsTestFailure.rejected
        let model = MobileIrohSettingsModel(controller: controller)

        let saved = await model.upsertCustomRelay(
            CmxIrohCustomRelayDraft(
                displayName: "Relay",
                provider: "Self-hosted",
                region: "Home",
                url: "https://relay.example.test",
                authMode: .none
            ),
            deviceSecret: nil
        )

        #expect(!saved)
        #expect(model.snapshot == committed)
        #expect(model.showsSaveError)
    }

    @Test func cancellingObservationRejectsSubsequentUpdates() async {
        let initial = snapshot(sequence: 1)
        let update = snapshot(sequence: 2)
        let ignored = snapshot(sequence: 3)
        let controller = MobileIrohSettingsControllerDouble(snapshot: initial)
        let model = MobileIrohSettingsModel(controller: controller)
        let observation = Task { await model.observe() }
        await waitUntil { controller.streamCreations == 1 }
        controller.continuation.yield(update)
        await waitUntil { model.snapshot == update }

        observation.cancel()
        await observation.value
        controller.continuation.yield(ignored)
        for _ in 0..<20 { await Task.yield() }

        #expect(model.snapshot == update)
        #expect(controller.streamTerminated)
    }

    @Test func emptyManagedSelectionNeverReachesController() async {
        let controller = MobileIrohSettingsControllerDouble(snapshot: .unavailable)
        let model = MobileIrohSettingsModel(controller: controller)

        model.setPreference(.managed([]))
        await waitUntil { model.showsSaveError }

        #expect(controller.preferenceMutations.isEmpty)
        #expect(model.snapshot == .unavailable)
    }

    private func waitUntil(_ predicate: () -> Bool) async {
        var spins = 0
        while !predicate(), spins < 100_000 {
            await Task.yield()
            spins += 1
        }
        #expect(predicate())
    }

    private func snapshot(sequence: Int64) -> CmxIrohSettingsSnapshot {
        CmxIrohSettingsSnapshot(
            runtimeStatus: .active,
            preference: .automatic,
            managedRelays: [],
            customRelays: [],
            policySource: .server,
            policySequence: sequence
        )
    }
}

@MainActor
private final class MobileIrohSettingsControllerDouble: CmxIrohSettingsControlling {
    var snapshot: CmxIrohSettingsSnapshot
    var preferenceMutations: [CmxIrohRelayPreferenceDraft] = []
    var upsertError: Error?
    var snapshotAfterUpsertError: CmxIrohSettingsSnapshot?
    var streamCreations = 0
    var streamTerminated = false
    let continuation: AsyncStream<CmxIrohSettingsSnapshot>.Continuation
    private let stream: AsyncStream<CmxIrohSettingsSnapshot>

    init(snapshot: CmxIrohSettingsSnapshot) {
        self.snapshot = snapshot
        (stream, continuation) = AsyncStream.makeStream()
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.streamTerminated = true }
        }
    }

    func irohSettingsSnapshot() async -> CmxIrohSettingsSnapshot { snapshot }

    func irohSettingsUpdates() -> AsyncStream<CmxIrohSettingsSnapshot> {
        streamCreations += 1
        return stream
    }

    func setIrohRelayPreference(_ preference: CmxIrohRelayPreferenceDraft) async throws {
        preferenceMutations.append(preference)
    }
    func upsertIrohCustomRelay(_ relay: CmxIrohCustomRelayDraft, deviceSecret: String?) async throws {
        if let upsertError {
            if let snapshotAfterUpsertError {
                snapshot = snapshotAfterUpsertError
            }
            throw upsertError
        }
    }
    func removeIrohCustomRelay(id: String) async throws {}
    func testIrohCustomRelay(id: String) async -> CmxIrohRelayTestResult { .failed }

    func refreshIrohSettings() async {}
}

private enum MobileIrohSettingsTestFailure: Error {
    case rejected
}
#endif
