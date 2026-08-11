#if os(iOS)
import CMUXMobileCore
import CmuxMobileDiagnostics
import Foundation
import Observation

@MainActor
@Observable
final class MobileIrohSettingsModel {
    private let controller: any CmxIrohSettingsControlling
    private let diagnosticLog: DiagnosticLog?

    var diagnosticLogForView: DiagnosticLog? { diagnosticLog }

    private(set) var snapshot = CmxIrohSettingsSnapshot.unavailable
    private(set) var isMutating = false
    private(set) var showsSaveError = false
    private(set) var testResults: [String: CmxIrohRelayTestResult] = [:]
    private(set) var diagnosticReport = DiagnosticReport.empty
    private(set) var diagnosticExportText = ""
    private(set) var verboseLogEnabled = UserDefaults.standard.bool(
        forKey: MobileDebugLog.verboseLogDefaultsKey
    )
    private var diagnosticReloadGeneration: UInt64 = 0

    /// The durable verbose log file, offered for sharing once it exists.
    var verboseLogShareURL: URL? {
        guard let url = MobileDebugLog.logFileURL,
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    func setVerboseLog(_ enabled: Bool) async {
        verboseLogEnabled = enabled
        let accepted = await MobileDebugLog.shared.setFileLogging(enabled: enabled)
        if !accepted {
            verboseLogEnabled = false
        }
        diagnosticLog?.recordAppEvent(
            .verboseDiagnosticLoggingChanged,
            failure: accepted ? nil : .permissionDenied,
            count: verboseLogEnabled ? 1 : 0
        )
    }

    init(
        controller: any CmxIrohSettingsControlling,
        diagnosticLog: DiagnosticLog? = nil
    ) {
        self.controller = controller
        self.diagnosticLog = diagnosticLog
    }

    func observe() async {
        diagnosticLog?.recordAppEvent(.irohSettingsOpened)
        defer { diagnosticLog?.recordAppEvent(.irohSettingsClosed) }
        snapshot = await controller.irohSettingsSnapshot()
        await reloadDiagnostics()
        for await next in controller.irohSettingsUpdates() {
            guard !Task.isCancelled else { return }
            snapshot = next
            await reloadDiagnostics()
        }
    }

    func refresh() {
        Task {
            await controller.refreshIrohSettings()
            snapshot = await controller.irohSettingsSnapshot()
            await reloadDiagnostics()
        }
    }

    func clearDiagnosticReport() async {
        guard !isMutating else { return }
        isMutating = true
        diagnosticReloadGeneration &+= 1
        defer { isMutating = false }
        diagnosticLog?.recordAppEvent(.irohDiagnosticsCleared)
        await controller.clearIrohDiagnosticReport()
        await reloadDiagnostics()
    }

    func setPreference(_ preference: CmxIrohRelayPreferenceDraft) {
        mutate(
            started: .irohRelayPreferenceChangeStarted,
            succeeded: .irohRelayPreferenceChangeSucceeded,
            failed: .irohRelayPreferenceChangeFailed
        ) {
            try await self.controller.setIrohRelayPreference(try preference.validated())
        }
    }

    func setPathPreference(_ preference: CmxIrohPathPreference) {
        mutate(
            started: .irohPathPreferenceChangeStarted,
            succeeded: .irohPathPreferenceChangeSucceeded,
            failed: .irohPathPreferenceChangeFailed
        ) {
            try await self.controller.setIrohPathPreference(preference)
        }
    }

    #if DEBUG
    func setDebugTransportVerificationMode(
        _ mode: CmxIrohTransportVerificationMode
    ) {
        mutate(
            started: .irohPathPreferenceChangeStarted,
            succeeded: .irohPathPreferenceChangeSucceeded,
            failed: .irohPathPreferenceChangeFailed
        ) {
            guard let debugController = self.controller
                as? any CmxIrohDebugSettingsControlling else { return }
            try await debugController.setIrohDebugTransportVerificationMode(mode)
        }
    }
    #endif

    func upsertCustomRelay(_ relay: CmxIrohCustomRelayDraft, deviceSecret: String?) async -> Bool {
        await mutateAndWait(
            started: .irohCustomRelayUpsertStarted,
            succeeded: .irohCustomRelayUpsertSucceeded,
            failed: .irohCustomRelayUpsertFailed,
            correlationID: relay.id
        ) {
            try await self.controller.upsertIrohCustomRelay(relay, deviceSecret: deviceSecret)
        }
    }

    func removeCustomRelay(id: String) {
        mutate(
            started: .irohCustomRelayRemoveStarted,
            succeeded: .irohCustomRelayRemoveSucceeded,
            failed: .irohCustomRelayRemoveFailed,
            correlationID: id
        ) {
            try await self.controller.removeIrohCustomRelay(id: id)
        }
    }

    func testCustomRelay(id: String) {
        diagnosticLog?.recordAppEvent(.irohCustomRelayTestStarted, correlationID: id)
        Task {
            let result = await controller.testIrohCustomRelay(id: id)
            testResults[id] = result
            switch result {
            case .reachable:
                diagnosticLog?.recordAppEvent(
                    .irohCustomRelayTestSucceeded,
                    correlationID: id
                )
            case .incomplete:
                diagnosticLog?.recordAppEvent(
                    .irohCustomRelayTestFailed,
                    correlationID: id,
                    failure: .policyUnavailable
                )
            case .failed:
                diagnosticLog?.recordAppEvent(
                    .irohCustomRelayTestFailed,
                    correlationID: id,
                    failure: .hostUnreachable
                )
            }
        }
    }

    func upsertCustomPrivatePath(
        _ path: CmxIrohCustomPrivatePathDraft
    ) async -> Bool {
        await mutateAndWait(
            started: .irohPrivatePathUpsertStarted,
            succeeded: .irohPrivatePathUpsertSucceeded,
            failed: .irohPrivatePathUpsertFailed,
            correlationID: path.macDeviceID
        ) {
            try await self.controller.upsertIrohCustomPrivatePath(path)
        }
    }

    func removeCustomPrivatePath(macDeviceID: String) {
        mutate(
            started: .irohPrivatePathRemoveStarted,
            succeeded: .irohPrivatePathRemoveSucceeded,
            failed: .irohPrivatePathRemoveFailed,
            correlationID: macDeviceID
        ) {
            try await self.controller.removeIrohCustomPrivatePath(
                macDeviceID: macDeviceID
            )
        }
    }

    func clearSaveError() {
        showsSaveError = false
    }

    private func mutate(
        started: DiagnosticAppEventKind,
        succeeded: DiagnosticAppEventKind,
        failed: DiagnosticAppEventKind,
        correlationID: String? = nil,
        _ operation: @escaping @MainActor () async throws -> Void
    ) {
        Task {
            _ = await mutateAndWait(
                started: started,
                succeeded: succeeded,
                failed: failed,
                correlationID: correlationID,
                operation
            )
        }
    }

    private func mutateAndWait(
        started: DiagnosticAppEventKind,
        succeeded: DiagnosticAppEventKind,
        failed: DiagnosticAppEventKind,
        correlationID: String? = nil,
        _ operation: @MainActor () async throws -> Void
    ) async -> Bool {
        guard !isMutating else {
            diagnosticLog?.recordAppEvent(
                failed,
                correlationID: correlationID,
                failure: .superseded
            )
            return false
        }
        isMutating = true
        diagnosticLog?.recordAppEvent(started, correlationID: correlationID)
        defer { isMutating = false }
        do {
            try await operation()
            snapshot = await controller.irohSettingsSnapshot()
            diagnosticLog?.recordAppEvent(succeeded, correlationID: correlationID)
            return true
        } catch {
            snapshot = await controller.irohSettingsSnapshot()
            showsSaveError = true
            diagnosticLog?.recordAppEvent(
                failed,
                correlationID: correlationID,
                failure: DiagnosticFailureKind.classify(error)
            )
            return false
        }
    }

    private func reloadDiagnostics() async {
        diagnosticReloadGeneration &+= 1
        let generation = diagnosticReloadGeneration
        let report = await controller.irohDiagnosticReport()
        let previous = await controller.irohPreviousLaunchDiagnosticReport()
        // The export carries the previous launch's archived block first so a
        // drop that happened before a relaunch stays in the shared timeline.
        let reports = [previous, report].compactMap { block -> DiagnosticReport? in
            guard let block, !block.events.isEmpty else { return nil }
            return block
        }
        var blocks: [String] = []
        blocks.reserveCapacity(reports.count)
        for report in reports {
            blocks.append(await report.humanReadableText())
        }
        guard generation == diagnosticReloadGeneration else { return }
        diagnosticReport = report
        diagnosticExportText = blocks.joined(separator: "\n")
    }
}
#endif
