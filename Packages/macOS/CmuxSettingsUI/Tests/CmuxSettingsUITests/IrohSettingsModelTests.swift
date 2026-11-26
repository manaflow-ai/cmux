import CMUXMobileCore
import Foundation
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

    @Test func observationLoadsSafeDiagnosticReportAndExportText() async {
        let controller = IrohSettingsControllerDouble(snapshot: .unavailable)
        let report = diagnosticReport()
        controller.report = report
        controller.exportData = report.humanReadableExport()
        let model = IrohSettingsModel(controller: controller)

        let observation = Task { await model.observe() }
        await waitUntil { model.diagnosticReport == report }
        observation.cancel()
        await observation.value

        #expect(
            model.diagnosticExportText
                == String(decoding: report.humanReadableExport(), as: UTF8.self)
        )
        #expect(model.diagnosticReport.events.count == 2)
        #expect(model.diagnosticReport.lastFailureKind == .timedOut)
    }

    @Test func clearDiagnosticReportClearsControllerAndReloadsModel() async {
        let controller = IrohSettingsControllerDouble(snapshot: .unavailable)
        controller.report = diagnosticReport()
        controller.exportData = controller.report.humanReadableExport()
        let model = IrohSettingsModel(controller: controller)
        let observation = Task { await model.observe() }
        await waitUntil { !model.diagnosticReport.events.isEmpty }
        observation.cancel()
        await observation.value

        await model.clearDiagnosticReport()

        #expect(controller.diagnosticClearCount == 1)
        #expect(model.diagnosticReport == .empty)
        #expect(model.diagnosticExportText.isEmpty)
        #expect(!model.isMutating)
    }

    @Test func stalePreClearDiagnosticReloadCannotRestoreClearedReport() async {
        let controller = IrohSettingsControllerDouble(snapshot: .unavailable)
        controller.holdsDiagnosticReportReads = true
        let model = IrohSettingsModel(controller: controller)

        let observation = Task { await model.observe() }
        await waitUntil { controller.pendingDiagnosticReportRequestIDs == [0] }

        let clear = Task { await model.clearDiagnosticReport() }
        await waitUntil { controller.pendingDiagnosticReportRequestIDs == [0, 1] }
        #expect(model.isMutating)

        controller.resumeDiagnosticReportRequest(1, returning: .empty)
        await clear.value
        controller.resumeDiagnosticReportRequest(0, returning: diagnosticReport())
        await waitUntil { controller.streamCreations == 1 }

        #expect(model.diagnosticReport == .empty)
        #expect(model.diagnosticExportText.isEmpty)
        observation.cancel()
        await observation.value
    }

    @Test func relayOnlyMutationForwardsThePathPreference() async {
        let controller = IrohSettingsControllerDouble(snapshot: .unavailable)
        let model = IrohSettingsModel(controller: controller)

        model.setPathPreference(.relayOnly)
        await waitUntil { controller.pathPreferenceMutations == [.relayOnly] }

        #expect(!model.showsSaveError)
    }

    @Test func neverUseRelaysMutationForwardsThePathPreference() async {
        let controller = IrohSettingsControllerDouble(snapshot: .unavailable)
        let model = IrohSettingsModel(controller: controller)

        model.setPathPreference(.neverUseRelays)
        await waitUntil { controller.pathPreferenceMutations == [.neverUseRelays] }

        #expect(!model.showsSaveError)
    }

    @Test func relayOnlyRestartNeverGatesTheControls() async {
        let controller = IrohSettingsControllerDouble(snapshot: .unavailable)
        controller.holdsPathPreferenceMutations = true
        let model = IrohSettingsModel(controller: controller)

        model.setPathPreference(.relayOnly)
        await waitUntil { controller.pendingPathPreferenceRequestIDs == [0] }
        // The Iroh restart is still in flight; the controls must stay usable.
        #expect(!model.isMutating)
        #expect(controller.pathPreferenceMutations == [.relayOnly])

        controller.resumePathPreferenceRequest(0)
        await waitUntil { controller.pendingPathPreferenceRequestIDs.isEmpty }
        #expect(!model.showsSaveError)
        #expect(!model.isMutating)
    }

    @Test func laterTransitionIntoDiagnosedDegradedRunsConnectionCheckOnce() async {
        let controller = IrohSettingsControllerDouble(
            snapshot: snapshot(sequence: 1, selectedRelayIDs: ["use1"])
        )
        controller.report = diagnosticReport()
        let model = IrohSettingsModel(controller: controller)
        let observation = Task { await model.observe() }
        await waitUntil { controller.streamCreations == 1 }

        let degraded = snapshot(
            sequence: 2,
            selectedRelayIDs: ["use1"],
            runtimeStatus: .degraded
        )
        controller.snapshot = degraded
        controller.continuation.yield(degraded)
        await waitUntil { controller.connectionCheckRunCount == 1 }
        controller.continuation.yield(degraded)
        // Each accepted snapshot reloads diagnostics exactly once, and the
        // completed check reloads once more, so the duplicate update is
        // proven consumed when the fourth diagnostics read lands.
        await waitUntil { controller.diagnosticReportReadCount == 4 }

        #expect(controller.connectionCheckRunCount == 1)
        observation.cancel()
        await observation.value
    }

    @Test func degradedTransitionWithoutDiagnosedFailureDoesNotAutoRunCheck() async {
        let controller = IrohSettingsControllerDouble(
            snapshot: snapshot(sequence: 1, selectedRelayIDs: ["use1"])
        )
        let model = IrohSettingsModel(controller: controller)
        let observation = Task { await model.observe() }
        await waitUntil { controller.streamCreations == 1 }

        let degraded = snapshot(
            sequence: 2,
            selectedRelayIDs: ["use1"],
            runtimeStatus: .degraded
        )
        controller.snapshot = degraded
        controller.continuation.yield(degraded)
        // The observe loop is sequential, so accepting the follow-up update
        // proves the degraded transition finished without starting a check.
        controller.continuation.yield(
            snapshot(sequence: 3, selectedRelayIDs: ["use1"], runtimeStatus: .degraded)
        )
        await waitUntil { controller.diagnosticReportReadCount == 3 }

        #expect(controller.connectionCheckRunCount == 0)
        observation.cancel()
        await observation.value
    }

    @Test func rapidManualCheckStartsCoalesceIntoASingleRun() async {
        let controller = IrohSettingsControllerDouble(snapshot: .unavailable)
        controller.connectionCheck = CmxIrohConnectionCheckReport(
            role: .macHost,
            snapshot: .unavailable,
            diagnostics: .empty,
            relayReachability: .unreachable
        )
        let model = IrohSettingsModel(controller: controller)

        model.runConnectionCheck()
        model.runConnectionCheck()
        await waitUntil { model.connectionCheck == controller.connectionCheck }

        #expect(controller.connectionCheckRunCount == 1)
        #expect(!model.isRunningConnectionCheck)
    }

    @Test func cancelledCheckNeverPublishesAndRestartRunsFresh() async {
        let controller = IrohSettingsControllerDouble(snapshot: .unavailable)
        controller.holdsConnectionCheckRuns = true
        controller.connectionCheck = CmxIrohConnectionCheckReport(
            role: .macHost,
            snapshot: .unavailable,
            diagnostics: .empty,
            relayReachability: .unreachable
        )
        let model = IrohSettingsModel(controller: controller)

        model.runConnectionCheck()
        await waitUntil { controller.pendingConnectionCheckRequestIDs == [0] }
        model.cancelConnectionCheck()
        controller.resumeConnectionCheckRequest(0)
        await waitUntil { !model.isRunningConnectionCheck }
        #expect(model.connectionCheck == nil)

        model.runConnectionCheck()
        await waitUntil { controller.pendingConnectionCheckRequestIDs == [1] }
        controller.resumeConnectionCheckRequest(1)
        await waitUntil { model.connectionCheck == controller.connectionCheck }
        #expect(controller.connectionCheckRunCount == 2)
    }

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
        selectedRelayIDs: Set<String>,
        runtimeStatus: CmxIrohSettingsSnapshot.RuntimeStatus = .active
    ) -> CmxIrohSettingsSnapshot {
        CmxIrohSettingsSnapshot(
            runtimeStatus: runtimeStatus,
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

    private func diagnosticReport() -> DiagnosticReport {
        DiagnosticReport(
            role: .macHost,
            generatedAt: Date(timeIntervalSince1970: 200),
            anchorWallNanos: 100_000_000_000,
            anchorMonotonicNanos: 1_000,
            buildStamp: "test",
            events: [
                DiagnosticEvent(
                    code: .transportDialConnected,
                    tNanos: 2_000,
                    a: Int(DiagnosticTransportKind.iroh.rawValue),
                    c: 7
                ),
                DiagnosticEvent(
                    code: .transportDialFailed,
                    tNanos: 3_000,
                    a: Int(DiagnosticTransportKind.iroh.rawValue),
                    b: Int(DiagnosticFailureKind.timedOut.rawValue),
                    c: 8
                ),
            ]
        )
    }
}

@MainActor
private final class IrohSettingsControllerDouble:
    CmxIrohSettingsControlling
{
    struct CustomRelayMutation: Equatable {
        let relay: CmxIrohCustomRelayDraft
        let deviceSecret: String?
    }

    var snapshot: CmxIrohSettingsSnapshot
    var preferenceMutations: [CmxIrohRelayPreferenceDraft] = []
    var pathPreferenceMutations: [CmxIrohPathPreference] = []
    var holdsPathPreferenceMutations = false
    private(set) var nextPathPreferenceRequestID = 0
    private var pendingPathPreferenceMutations: [
        Int: CheckedContinuation<Void, Never>
    ] = [:]
    var customRelayMutations: [CustomRelayMutation] = []
    var customRelayError: Error?
    var snapshotAfterCustomRelayError: CmxIrohSettingsSnapshot?
    var streamCreations = 0
    var streamTerminated = false
    var report = DiagnosticReport.empty
    var exportData = Data()
    var diagnosticClearCount = 0
    var connectionCheck: CmxIrohConnectionCheckReport?
    var connectionCheckRunCount = 0
    var holdsConnectionCheckRuns = false
    private(set) var nextConnectionCheckRequestID = 0
    private var pendingConnectionCheckRuns: [
        Int: CheckedContinuation<Void, Never>
    ] = [:]
    private(set) var diagnosticReportReadCount = 0
    var holdsDiagnosticReportReads = false
    private(set) var nextDiagnosticReportRequestID = 0
    private var pendingDiagnosticReportReads: [
        Int: CheckedContinuation<DiagnosticReport, Never>
    ] = [:]
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

    func setIrohPathPreference(_ preference: CmxIrohPathPreference) async throws {
        pathPreferenceMutations.append(preference)
        if holdsPathPreferenceMutations {
            let requestID = nextPathPreferenceRequestID
            nextPathPreferenceRequestID += 1
            await withCheckedContinuation {
                (continuation: CheckedContinuation<Void, Never>) in
                pendingPathPreferenceMutations[requestID] = continuation
            }
        }
    }

    var pendingPathPreferenceRequestIDs: [Int] {
        pendingPathPreferenceMutations.keys.sorted()
    }

    func resumePathPreferenceRequest(_ id: Int) {
        pendingPathPreferenceMutations.removeValue(forKey: id)?.resume()
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

    func runIrohConnectionCheck() async -> CmxIrohConnectionCheckReport {
        connectionCheckRunCount += 1
        if holdsConnectionCheckRuns {
            let requestID = nextConnectionCheckRequestID
            nextConnectionCheckRequestID += 1
            await withCheckedContinuation {
                (continuation: CheckedContinuation<Void, Never>) in
                pendingConnectionCheckRuns[requestID] = continuation
            }
        }
        return connectionCheck ?? CmxIrohConnectionCheckReport(
            role: .macHost,
            snapshot: snapshot,
            diagnostics: report,
            relayReachability: .unavailable
        )
    }

    var pendingConnectionCheckRequestIDs: [Int] {
        pendingConnectionCheckRuns.keys.sorted()
    }

    func resumeConnectionCheckRequest(_ id: Int) {
        pendingConnectionCheckRuns.removeValue(forKey: id)?.resume()
    }

    func irohDiagnosticReport() async -> DiagnosticReport {
        diagnosticReportReadCount += 1
        guard holdsDiagnosticReportReads else { return report }
        let requestID = nextDiagnosticReportRequestID
        nextDiagnosticReportRequestID += 1
        return await withCheckedContinuation { continuation in
            pendingDiagnosticReportReads[requestID] = continuation
        }
    }

    var pendingDiagnosticReportRequestIDs: [Int] {
        pendingDiagnosticReportReads.keys.sorted()
    }

    func resumeDiagnosticReportRequest(_ id: Int, returning report: DiagnosticReport) {
        pendingDiagnosticReportReads.removeValue(forKey: id)?.resume(returning: report)
    }

    func exportIrohDiagnosticReport() async -> Data { exportData }

    func clearIrohDiagnosticReport() async {
        diagnosticClearCount += 1
        report = .empty
        exportData = Data()
    }

}

private enum TestFailure: Error {
    case rejected
}
