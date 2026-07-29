import CMUXMobileCore
import Observation

/// Main-actor projection of the app's Iroh settings controller for SwiftUI.
@MainActor
@Observable
final class IrohSettingsModel {
    private let controller: (any CmxIrohSettingsControlling)?
    private let privateNetworkAddressProvider: @MainActor () -> [CmxPrivateNetworkAddress]
    private let mobileDirectPortProvider: @MainActor () -> Int

    private(set) var snapshot = CmxIrohSettingsSnapshot.unavailable
    private(set) var localPrivateNetworkAddresses: [CmxPrivateNetworkAddress]
    private(set) var mobileDirectPort: Int
    private(set) var isMutating = false
    private(set) var showsSaveError = false
    private(set) var testResults: [String: CmxIrohRelayTestResult] = [:]
    private(set) var diagnosticReport = DiagnosticReport.empty
    private(set) var diagnosticExportText = ""
    private var diagnosticReloadGeneration: UInt64 = 0

    init(
        controller: (any CmxIrohSettingsControlling)?,
        privateNetworkAddressProvider: @escaping @MainActor () -> [CmxPrivateNetworkAddress] = { [] },
        mobileDirectPortProvider: @escaping @MainActor () -> Int = { 0 }
    ) {
        self.controller = controller
        self.privateNetworkAddressProvider = privateNetworkAddressProvider
        self.mobileDirectPortProvider = mobileDirectPortProvider
        localPrivateNetworkAddresses = privateNetworkAddressProvider()
        mobileDirectPort = mobileDirectPortProvider()
    }

    func observe() async {
        refreshHostSnapshot()
        guard let controller else { return }
        snapshot = await controller.irohSettingsSnapshot()
        await reloadDiagnostics(using: controller)
        for await next in controller.irohSettingsUpdates() {
            guard !Task.isCancelled else { return }
            snapshot = next
            refreshHostSnapshot()
            await reloadDiagnostics(using: controller)
        }
    }

    func refresh() {
        refreshHostSnapshot()
        guard let controller else { return }
        Task {
            await controller.refreshIrohSettings()
            snapshot = await controller.irohSettingsSnapshot()
            refreshHostSnapshot()
            await reloadDiagnostics(using: controller)
        }
    }

    func clearDiagnosticReport() async {
        guard let controller, !isMutating else { return }
        isMutating = true
        diagnosticReloadGeneration &+= 1
        defer { isMutating = false }
        await controller.clearIrohDiagnosticReport()
        await reloadDiagnostics(using: controller)
    }

    func setPreference(_ preference: CmxIrohRelayPreferenceDraft) {
        mutate { controller in
            try await controller.setIrohRelayPreference(try preference.validated())
        }
    }

    func setPathPreference(_ preference: CmxIrohPathPreference) {
        mutate { controller in
            try await controller.setIrohPathPreference(preference)
        }
    }

    func upsertCustomRelay(_ relay: CmxIrohCustomRelayDraft, deviceSecret: String?) async -> Bool {
        await mutateAndWait { controller in
            try await controller.upsertIrohCustomRelay(relay, deviceSecret: deviceSecret)
        }
    }

    func removeCustomRelay(id: String) {
        mutate { controller in
            try await controller.removeIrohCustomRelay(id: id)
        }
    }

    func testCustomRelay(id: String) {
        guard let controller else { return }
        Task {
            testResults[id] = await controller.testIrohCustomRelay(id: id)
        }
    }

    func clearSaveError() {
        showsSaveError = false
    }

    private func mutate(
        _ operation: @escaping @MainActor (any CmxIrohSettingsControlling) async throws -> Void
    ) {
        Task { _ = await mutateAndWait(operation) }
    }

    private func mutateAndWait(
        _ operation: @MainActor (any CmxIrohSettingsControlling) async throws -> Void
    ) async -> Bool {
        guard let controller, !isMutating else { return false }
        isMutating = true
        defer { isMutating = false }
        do {
            try await operation(controller)
            snapshot = await controller.irohSettingsSnapshot()
            return true
        } catch {
            snapshot = await controller.irohSettingsSnapshot()
            showsSaveError = true
            return false
        }
    }

    private func reloadDiagnostics(using controller: any CmxIrohSettingsControlling) async {
        diagnosticReloadGeneration &+= 1
        let generation = diagnosticReloadGeneration
        let report = await controller.irohDiagnosticReport()
        guard generation == diagnosticReloadGeneration else { return }
        diagnosticReport = report
        diagnosticExportText = report.events.isEmpty
            ? ""
            : String(decoding: report.compactExport(), as: UTF8.self)
    }

    private func refreshHostSnapshot() {
        localPrivateNetworkAddresses = CmxPrivateNetworkAddress.sorted(
            privateNetworkAddressProvider()
        )
        mobileDirectPort = mobileDirectPortProvider()
    }
}
