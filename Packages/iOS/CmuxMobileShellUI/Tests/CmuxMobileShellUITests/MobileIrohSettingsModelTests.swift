#if os(iOS)
import CMUXMobileCore
import Foundation
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

    @Test func customPrivatePathMutationsForwardExactMacScopedDraft() async {
        let controller = MobileIrohSettingsControllerDouble(snapshot: .unavailable)
        let model = MobileIrohSettingsModel(controller: controller)
        let draft = CmxIrohCustomPrivatePathDraft(
            macDeviceID: "123e4567-e89b-42d3-a456-426614174004",
            macDisplayName: "Work Mac",
            addresses: ["10.0.0.8", "fd00::8"],
            isEnabled: true
        )

        #expect(await model.upsertCustomPrivatePath(draft))
        #expect(controller.customPrivatePathUpserts == [draft])

        model.removeCustomPrivatePath(macDeviceID: draft.macDeviceID)
        await waitUntil {
            controller.customPrivatePathRemovals == [draft.macDeviceID]
        }
    }

    @Test func observationLoadsSafeDiagnosticReportAndExportText() async {
        let controller = MobileIrohSettingsControllerDouble(snapshot: .unavailable)
        let report = diagnosticReport()
        controller.report = report
        controller.exportData = Data("cmuxdiag v1\n25,1,,,1,,7".utf8)
        let model = MobileIrohSettingsModel(controller: controller)

        let observation = Task { await model.observe() }
        await waitUntil { model.diagnosticReport == report }
        observation.cancel()
        await observation.value

        #expect(model.diagnosticExportText == String(decoding: report.compactExport(), as: UTF8.self))
        #expect(model.diagnosticReport.events.count == 2)
        #expect(model.diagnosticReport.lastFailureKind == .timedOut)
    }

    @Test func clearDiagnosticReportClearsControllerAndReloadsModel() async {
        let controller = MobileIrohSettingsControllerDouble(snapshot: .unavailable)
        controller.report = diagnosticReport()
        controller.exportData = Data("cmuxdiag v1\n25,1,,,1,,7".utf8)
        let model = MobileIrohSettingsModel(controller: controller)
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
        let controller = MobileIrohSettingsControllerDouble(snapshot: .unavailable)
        controller.holdsDiagnosticReportReads = true
        let model = MobileIrohSettingsModel(controller: controller)

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

    #if DEBUG
    @Test func debugTransportModeForwardsEveryChoiceAndRefreshesSnapshot() async {
        let controller = MobileIrohSettingsControllerDouble(
            snapshot: snapshot(sequence: 1, debugMode: .automatic)
        )
        let model = MobileIrohSettingsModel(controller: controller)

        for mode in CmxIrohTransportVerificationMode.allCases {
            model.setDebugTransportVerificationMode(mode)
            await waitUntil {
                controller.debugTransportModeMutations.last == mode
                    && model.snapshot.debugTransportVerificationMode == mode
                    && !model.isMutating
            }
        }

        #expect(controller.debugTransportModeMutations == CmxIrohTransportVerificationMode.allCases)
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
        debugMode: CmxIrohTransportVerificationMode? = nil
    ) -> CmxIrohSettingsSnapshot {
        CmxIrohSettingsSnapshot(
            runtimeStatus: .active,
            preference: .automatic,
            managedRelays: [],
            customRelays: [],
            policySource: .server,
            policySequence: sequence,
            debugTransportVerificationMode: debugMode
        )
    }

    private func diagnosticReport() -> DiagnosticReport {
        DiagnosticReport(
            role: .mobileClient,
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
                )
            ]
        )
    }
}

@MainActor
private final class MobileIrohSettingsControllerDouble:
    CmxIrohSettingsControlling,
    CmxIrohDebugSettingsControlling
{
    var snapshot: CmxIrohSettingsSnapshot
    var preferenceMutations: [CmxIrohRelayPreferenceDraft] = []
    var upsertError: Error?
    var snapshotAfterUpsertError: CmxIrohSettingsSnapshot?
    var streamCreations = 0
    var streamTerminated = false
    var report = DiagnosticReport.empty
    var exportData = Data()
    var diagnosticClearCount = 0
    var debugTransportModeMutations: [CmxIrohTransportVerificationMode] = []
    var customPrivatePathUpserts: [CmxIrohCustomPrivatePathDraft] = []
    var customPrivatePathRemovals: [String] = []
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

    func upsertIrohCustomPrivatePath(
        _ path: CmxIrohCustomPrivatePathDraft
    ) async throws {
        customPrivatePathUpserts.append(path)
    }

    func removeIrohCustomPrivatePath(macDeviceID: String) async throws {
        customPrivatePathRemovals.append(macDeviceID)
    }

    func refreshIrohSettings() async {}

    func irohDiagnosticReport() async -> DiagnosticReport {
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

    func setIrohDebugTransportVerificationMode(
        _ mode: CmxIrohTransportVerificationMode
    ) async throws {
        debugTransportModeMutations.append(mode)
        snapshot = CmxIrohSettingsSnapshot(
            runtimeStatus: snapshot.runtimeStatus,
            selectedTransportPath: snapshot.selectedTransportPath,
            preference: snapshot.preference,
            managedRelays: snapshot.managedRelays,
            customRelays: snapshot.customRelays,
            privateNetworkMacs: snapshot.privateNetworkMacs,
            customPrivateNetworks: snapshot.customPrivateNetworks,
            policySource: snapshot.policySource,
            policySequence: snapshot.policySequence,
            policyExpiresAt: snapshot.policyExpiresAt,
            staleRelayIDs: snapshot.staleRelayIDs,
            failureDescription: snapshot.failureDescription,
            debugTransportVerificationMode: mode
        )
    }
}

private enum MobileIrohSettingsTestFailure: Error {
    case rejected
}
#endif
