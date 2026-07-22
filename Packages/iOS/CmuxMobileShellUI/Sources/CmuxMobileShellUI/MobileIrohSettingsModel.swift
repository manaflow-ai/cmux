#if os(iOS)
import CMUXMobileCore
import Observation

@MainActor
@Observable
final class MobileIrohSettingsModel {
    private let controller: any CmxIrohSettingsControlling

    private(set) var snapshot = CmxIrohSettingsSnapshot.unavailable
    private(set) var isMutating = false
    private(set) var showsSaveError = false
    private(set) var testResults: [String: CmxIrohRelayTestResult] = [:]
    private(set) var diagnosticReport = DiagnosticReport.empty
    private(set) var diagnosticExportText = ""
    private var diagnosticReloadGeneration: UInt64 = 0

    init(controller: any CmxIrohSettingsControlling) {
        self.controller = controller
    }

    func observe() async {
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
        await controller.clearIrohDiagnosticReport()
        await reloadDiagnostics()
    }

    func setPreference(_ preference: CmxIrohRelayPreferenceDraft) {
        mutate { try await self.controller.setIrohRelayPreference(try preference.validated()) }
    }

    #if DEBUG
    func setDebugTransportVerificationMode(
        _ mode: CmxIrohTransportVerificationMode
    ) {
        mutate {
            guard let debugController = self.controller
                as? any CmxIrohDebugSettingsControlling else { return }
            try await debugController.setIrohDebugTransportVerificationMode(mode)
        }
    }
    #endif

    func upsertCustomRelay(_ relay: CmxIrohCustomRelayDraft, deviceSecret: String?) async -> Bool {
        await mutateAndWait {
            try await self.controller.upsertIrohCustomRelay(relay, deviceSecret: deviceSecret)
        }
    }

    func removeCustomRelay(id: String) {
        mutate { try await self.controller.removeIrohCustomRelay(id: id) }
    }

    func testCustomRelay(id: String) {
        Task { testResults[id] = await controller.testIrohCustomRelay(id: id) }
    }

    func upsertCustomPrivatePath(
        _ path: CmxIrohCustomPrivatePathDraft
    ) async -> Bool {
        await mutateAndWait {
            try await self.controller.upsertIrohCustomPrivatePath(path)
        }
    }

    func removeCustomPrivatePath(macDeviceID: String) {
        mutate {
            try await self.controller.removeIrohCustomPrivatePath(
                macDeviceID: macDeviceID
            )
        }
    }

    func clearSaveError() {
        showsSaveError = false
    }

    private func mutate(_ operation: @escaping @MainActor () async throws -> Void) {
        Task { _ = await mutateAndWait(operation) }
    }

    private func mutateAndWait(_ operation: @MainActor () async throws -> Void) async -> Bool {
        guard !isMutating else { return false }
        isMutating = true
        defer { isMutating = false }
        do {
            try await operation()
            snapshot = await controller.irohSettingsSnapshot()
            return true
        } catch {
            snapshot = await controller.irohSettingsSnapshot()
            showsSaveError = true
            return false
        }
    }

    private func reloadDiagnostics() async {
        diagnosticReloadGeneration &+= 1
        let generation = diagnosticReloadGeneration
        let report = await controller.irohDiagnosticReport()
        guard generation == diagnosticReloadGeneration else { return }
        diagnosticReport = report
        diagnosticExportText = report.events.isEmpty
            ? ""
            : String(decoding: report.compactExport(), as: UTF8.self)
    }
}
#endif
