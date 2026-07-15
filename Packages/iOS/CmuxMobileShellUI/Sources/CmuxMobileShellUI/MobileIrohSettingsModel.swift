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

    init(controller: any CmxIrohSettingsControlling) {
        self.controller = controller
    }

    func observe() async {
        snapshot = await controller.irohSettingsSnapshot()
        for await next in controller.irohSettingsUpdates() {
            guard !Task.isCancelled else { return }
            snapshot = next
        }
    }

    func refresh() {
        Task {
            await controller.refreshIrohSettings()
            snapshot = await controller.irohSettingsSnapshot()
        }
    }

    func setPreference(_ preference: CmxIrohRelayPreferenceDraft) {
        mutate { try await self.controller.setIrohRelayPreference(try preference.validated()) }
    }

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
}
#endif
