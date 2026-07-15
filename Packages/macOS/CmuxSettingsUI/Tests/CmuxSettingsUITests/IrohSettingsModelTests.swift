import CMUXMobileCore
import Testing

@testable import CmuxSettingsUI

@MainActor
@Suite
struct IrohSettingsModelTests {
    @Test func successfulCustomRelaySaveForwardsMetadataAndDeviceSecret() async {
        let controller = IrohSettingsControllerDouble(snapshot: .unavailable)
        let model = IrohSettingsModel(controller: controller)
        let draft = CmxIrohCustomRelayDraft(
            displayName: "Personal Relay",
            provider: "Self-hosted",
            region: "Home",
            url: "https://relay.example.test",
            authMode: .deviceSecret
        )

        let saved = await model.upsertCustomRelay(draft, deviceSecret: "device-only-secret")

        #expect(saved)
        #expect(controller.customRelayMutations == [
            .init(relay: draft, deviceSecret: "device-only-secret"),
        ])
        #expect(!model.showsSaveError)
    }

    @Test func failedSavePreservesLastObservedSnapshotAndReportsFailure() async {
        let initial = snapshot(sequence: 7, selectedRelayIDs: ["use1"])
        let controller = IrohSettingsControllerDouble(snapshot: initial)
        let model = IrohSettingsModel(controller: controller)
        let observation = Task { await model.observe() }
        await waitUntil { model.snapshot == initial }
        observation.cancel()
        await observation.value
        controller.customRelayError = TestFailure.rejected

        let saved = await model.upsertCustomRelay(
            CmxIrohCustomRelayDraft(
                displayName: "Rejected",
                provider: "Self-hosted",
                region: "Home",
                url: "https://rejected.example.test",
                authMode: .none
            ),
            deviceSecret: nil
        )

        #expect(!saved)
        #expect(model.snapshot == initial)
        #expect(model.showsSaveError)
    }

    @Test func failedLocalFollowUpReconcilesToCommittedAccountSnapshot() async {
        let initial = snapshot(sequence: 7, selectedRelayIDs: ["use1"])
        let committed = snapshot(sequence: 8, selectedRelayIDs: ["euc1"])
        let controller = IrohSettingsControllerDouble(snapshot: initial)
        controller.snapshotAfterCustomRelayError = committed
        controller.customRelayError = TestFailure.rejected
        let model = IrohSettingsModel(controller: controller)

        let saved = await model.upsertCustomRelay(
            CmxIrohCustomRelayDraft(
                displayName: "Committed",
                provider: "Self-hosted",
                region: "Home",
                url: "https://committed.example.test",
                authMode: .none
            ),
            deviceSecret: nil
        )

        #expect(!saved)
        #expect(model.snapshot == committed)
        #expect(model.showsSaveError)
    }

    @Test func cancellingObservationPreventsLaterSnapshotDelivery() async {
        let initial = snapshot(sequence: 1, selectedRelayIDs: ["use1"])
        let firstUpdate = snapshot(sequence: 2, selectedRelayIDs: ["usw1"])
        let ignoredUpdate = snapshot(sequence: 3, selectedRelayIDs: ["euc1"])
        let controller = IrohSettingsControllerDouble(snapshot: initial)
        let model = IrohSettingsModel(controller: controller)
        let observation = Task { await model.observe() }
        await waitUntil { controller.streamCreations == 1 }

        controller.continuation.yield(firstUpdate)
        await waitUntil { model.snapshot == firstUpdate }
        observation.cancel()
        await observation.value
        controller.continuation.yield(ignoredUpdate)
        for _ in 0..<20 { await Task.yield() }

        #expect(model.snapshot == firstUpdate)
        #expect(controller.streamTerminated)
    }

    @Test func preferenceMutationForwardsTheExactManagedSelection() async {
        let controller = IrohSettingsControllerDouble(snapshot: .unavailable)
        let model = IrohSettingsModel(controller: controller)

        model.setPreference(.managed(["use1", "euc1"]))
        await waitUntil { controller.preferenceMutations.count == 1 }

        #expect(controller.preferenceMutations == [.managed(["use1", "euc1"])])
    }

    @Test func emptyManagedSelectionFailsBeforeControllerMutation() async {
        let controller = IrohSettingsControllerDouble(snapshot: .unavailable)
        let model = IrohSettingsModel(controller: controller)

        model.setPreference(.managed([]))
        await waitUntil { model.showsSaveError }

        #expect(controller.preferenceMutations.isEmpty)
        #expect(model.snapshot == .unavailable)
    }

    #if DEBUG
    @Test func relayOnlyMutationUsesTheDebugControllerBoundary() async {
        let controller = IrohSettingsControllerDouble(snapshot: .unavailable)
        let model = IrohSettingsModel(controller: controller)

        model.setDebugRelayOnly(true)
        await waitUntil { controller.debugRelayOnlyMutations == [true] }

        #expect(!model.showsSaveError)
    }
    #endif

    private func waitUntil(_ predicate: () -> Bool) async {
        var spins = 0
        while !predicate(), spins < 100_000 {
            await Task.yield()
            spins += 1
        }
        #expect(predicate())
    }

    private func snapshot(
        sequence: Int64,
        selectedRelayIDs: Set<String>
    ) -> CmxIrohSettingsSnapshot {
        CmxIrohSettingsSnapshot(
            runtimeStatus: .active,
            preference: .managed(selectedRelayIDs),
            managedRelays: selectedRelayIDs.sorted().map {
                .init(
                    id: $0,
                    provider: "cmux",
                    region: $0,
                    url: "https://\($0).relay.example.test",
                    isSelected: true
                )
            },
            customRelays: [],
            policySource: .server,
            policySequence: sequence
        )
    }
}

@MainActor
private final class IrohSettingsControllerDouble:
    CmxIrohSettingsControlling,
    CmxIrohDebugSettingsControlling
{
    struct CustomRelayMutation: Equatable {
        let relay: CmxIrohCustomRelayDraft
        let deviceSecret: String?
    }

    var snapshot: CmxIrohSettingsSnapshot
    var preferenceMutations: [CmxIrohRelayPreferenceDraft] = []
    var customRelayMutations: [CustomRelayMutation] = []
    var customRelayError: Error?
    var snapshotAfterCustomRelayError: CmxIrohSettingsSnapshot?
    var debugRelayOnlyMutations: [Bool] = []
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

    func upsertIrohCustomRelay(
        _ relay: CmxIrohCustomRelayDraft,
        deviceSecret: String?
    ) async throws {
        if let customRelayError {
            if let snapshotAfterCustomRelayError {
                snapshot = snapshotAfterCustomRelayError
            }
            throw customRelayError
        }
        customRelayMutations.append(.init(relay: relay, deviceSecret: deviceSecret))
    }

    func removeIrohCustomRelay(id: String) async throws {}
    func testIrohCustomRelay(id: String) async -> CmxIrohRelayTestResult { .failed }
    func refreshIrohSettings() async {}

    func setIrohDebugRelayOnly(_ enabled: Bool) async throws {
        debugRelayOnlyMutations.append(enabled)
    }
}

private enum TestFailure: Error {
    case rejected
}
