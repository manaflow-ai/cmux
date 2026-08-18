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
    private(set) var connectionCheck: CmxIrohConnectionCheckReport?
    private(set) var isRunningConnectionCheck = false
    private(set) var diagnosticReport = DiagnosticReport.empty
    private(set) var diagnosticExportText = ""
    private(set) var verboseLogEnabled = UserDefaults.standard.bool(
        forKey: MobileDebugLog.verboseLogDefaultsKey
    )
    private var diagnosticReloadGeneration: UInt64 = 0
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var mutationTask: Task<Void, Never>?
    @ObservationIgnored private var mutationToken: UUID?
    @ObservationIgnored private var relayTestTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var relayTestTokens: [String: UUID] = [:]
    @ObservationIgnored private var connectionCheckTask: Task<Void, Never>?
    @ObservationIgnored private var connectionCheckGeneration: UInt64 = 0

    var connectionCheckRelayURLs: [String] {
        modelRelayURLs
    }

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
        await acceptSnapshot(await controller.irohSettingsSnapshot(), previousStatus: nil)
        for await next in controller.irohSettingsUpdates() {
            guard !Task.isCancelled else { return }
            await acceptSnapshot(next, previousStatus: snapshot.runtimeStatus)
        }
    }

    func refresh() {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.controller.refreshIrohSettings()
            guard !Task.isCancelled else { return }
            self.snapshot = await self.controller.irohSettingsSnapshot()
            await self.reloadDiagnostics()
            guard !Task.isCancelled else { return }
            self.refreshTask = nil
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
        runRestartMutation { try await self.controller.setIrohPathPreference(preference) }
    }

    func resetToDefaults() {
        mutate(
            started: .irohPathPreferenceChangeStarted,
            succeeded: .irohPathPreferenceChangeSucceeded,
            failed: .irohPathPreferenceChangeFailed
        ) {
            try await self.controller.resetIrohSettingsToDefaults()
        }
    }

    #if DEBUG
    func setDebugTransportVerificationMode(
        _ mode: CmxIrohTransportVerificationMode
    ) {
        runRestartMutation {
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
        if let existingTask = relayTestTasks[id] {
            diagnosticLog?.recordAppEvent(
                .irohCustomRelayTestFailed,
                correlationID: id,
                failure: .superseded
            )
            existingTask.cancel()
        }
        diagnosticLog?.recordAppEvent(.irohCustomRelayTestStarted, correlationID: id)
        let token = UUID()
        relayTestTokens[id] = token
        relayTestTasks[id] = Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await self.controller.testIrohCustomRelay(id: id)
            guard !Task.isCancelled, self.relayTestTokens[id] == token else { return }
            self.testResults[id] = result
            switch result {
            case .reachable:
                self.diagnosticLog?.recordAppEvent(
                    .irohCustomRelayTestSucceeded,
                    correlationID: id
                )
            case .incomplete:
                self.diagnosticLog?.recordAppEvent(
                    .irohCustomRelayTestFailed,
                    correlationID: id,
                    failure: .policyUnavailable
                )
            case .failed:
                self.diagnosticLog?.recordAppEvent(
                    .irohCustomRelayTestFailed,
                    correlationID: id,
                    failure: .hostUnreachable
                )
            }
            self.relayTestTasks[id] = nil
            self.relayTestTokens[id] = nil
        }
    }

    func runConnectionCheck() {
        // Reserve ownership before the task starts so rapid calls cannot
        // create competing tasks whose cleanup clears each other's handle.
        guard connectionCheckTask == nil, !isRunningConnectionCheck else { return }
        connectionCheckGeneration &+= 1
        let generation = connectionCheckGeneration
        connectionCheckTask = Task { [weak self] in
            guard let self else { return }
            await runConnectionCheckAndWait()
            if connectionCheckGeneration == generation {
                connectionCheckTask = nil
            }
        }
    }

    func cancelConnectionCheck() {
        connectionCheckGeneration &+= 1
        connectionCheckTask?.cancel()
        connectionCheckTask = nil
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
        guard mutationTask == nil else {
            diagnosticLog?.recordAppEvent(
                failed,
                correlationID: correlationID,
                failure: .superseded
            )
            return
        }
        let token = UUID()
        mutationToken = token
        mutationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await self.mutateAndWait(
                started: started,
                succeeded: succeeded,
                failed: failed,
                correlationID: correlationID,
                operation
            )
            guard self.mutationToken == token else { return }
            self.mutationTask = nil
            self.mutationToken = nil
        }
    }

    /// Runs a mutation whose controller call persists the preference and
    /// publishes the new snapshot immediately, then restarts Iroh before
    /// returning. The restart can take tens of seconds, so it must not hold
    /// `isMutating` (which disables the whole sheet); the settings update
    /// stream reconciles the UI while the restart runs.
    private func runRestartMutation(
        started: DiagnosticAppEventKind = .irohPathPreferenceChangeStarted,
        succeeded: DiagnosticAppEventKind = .irohPathPreferenceChangeSucceeded,
        failed: DiagnosticAppEventKind = .irohPathPreferenceChangeFailed,
        _ operation: @escaping @MainActor () async throws -> Void
    ) {
        diagnosticLog?.recordAppEvent(started)
        Task {
            do {
                try await operation()
                snapshot = await controller.irohSettingsSnapshot()
                diagnosticLog?.recordAppEvent(succeeded)
            } catch {
                snapshot = await controller.irohSettingsSnapshot()
                showsSaveError = true
                diagnosticLog?.recordAppEvent(
                    failed,
                    failure: DiagnosticFailureKind.classify(error)
                )
            }
        }
    }

    /// Cancels settings work when its owning screen leaves the hierarchy.
    func cancelOperations() {
        refreshTask?.cancel()
        refreshTask = nil
        connectionCheckGeneration &+= 1
        connectionCheckTask?.cancel()
        connectionCheckTask = nil
        isRunningConnectionCheck = false
        mutationTask?.cancel()
        mutationTask = nil
        mutationToken = nil
        for id in relayTestTasks.keys {
            diagnosticLog?.recordAppEvent(
                .irohCustomRelayTestFailed,
                correlationID: id,
                failure: .cancelled
            )
        }
        relayTestTasks.values.forEach { $0.cancel() }
        relayTestTasks = [:]
        relayTestTokens = [:]
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
            try Task.checkCancellation()
            try await operation()
            try Task.checkCancellation()
            snapshot = await controller.irohSettingsSnapshot()
            diagnosticLog?.recordAppEvent(succeeded, correlationID: correlationID)
            return true
        } catch is CancellationError {
            diagnosticLog?.recordAppEvent(
                failed,
                correlationID: correlationID,
                failure: .cancelled
            )
            return false
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

    private func runConnectionCheckAndWait() async {
        guard !Task.isCancelled, !isRunningConnectionCheck else { return }
        isRunningConnectionCheck = true
        defer { isRunningConnectionCheck = false }
        let report = await controller.runIrohConnectionCheck()
        guard !Task.isCancelled else { return }
        let refreshedSnapshot = await controller.irohSettingsSnapshot()
        guard !Task.isCancelled else { return }
        connectionCheck = report
        snapshot = refreshedSnapshot
        await reloadDiagnostics()
    }

    private func acceptSnapshot(
        _ next: CmxIrohSettingsSnapshot,
        previousStatus: CmxIrohSettingsSnapshot.RuntimeStatus?
    ) async {
        snapshot = next
        await reloadDiagnostics()
        // Auto-diagnose only a diagnosed degraded entry: a connection failure
        // in diagnostics, or a relay-configuration failure on the snapshot
        // (relay-policy-only degradation carries no lastFailureKind).
        guard !Task.isCancelled,
              previousStatus != .degraded,
              next.runtimeStatus == .degraded,
              diagnosticReport.lastFailureKind != nil
                  || next.failureDescription != nil else { return }
        await runConnectionCheckAndWait()
    }

    deinit {
        refreshTask?.cancel()
        mutationTask?.cancel()
        connectionCheckTask?.cancel()
        relayTestTasks.values.forEach { $0.cancel() }
    }

    private var modelRelayURLs: [String] {
        snapshot.managedRelays.map(\.url) + snapshot.customRelays.map(\.url)
    }
}
#endif
