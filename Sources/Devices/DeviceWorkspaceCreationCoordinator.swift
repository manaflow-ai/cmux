import Foundation

/// Shares device workspace creation between synchronous shortcut and menu actions.
@MainActor
final class DeviceWorkspaceCreationCoordinator {
    private let operations: CloudWorkspaceOperationController
    private let create: @MainActor (SurfaceMachineID, TabManager) async throws -> Void

    init(
        operations: CloudWorkspaceOperationController,
        create: @escaping @MainActor (SurfaceMachineID, TabManager) async throws -> Void
    ) {
        self.operations = operations
        self.create = create
    }

    func start(on machine: SurfaceMachineID, in manager: TabManager) -> Bool {
        guard machine.isDevice else { return false }
        let origin = manager.selectedWorkspace
        return operations.start(key: "new-device-workspace." + machine.rawValue) { [create, weak manager, weak origin] in
            guard let manager else { return }
            do {
                try await create(machine, manager)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if let origin {
                    let requestID = origin.cloudPaneCreationFailureStore.beginRequest()
                    origin.cloudPaneCreationFailureStore.present(machine: machine, error: error, requestID: requestID,
                        title: String(localized: "applescript.error.failedToCreateWorkspace", defaultValue: "Failed to create workspace."),
                        recoveryText: String(localized: "devices.terminal.disconnected.detail",
                            defaultValue: "Your layout and scrollback are preserved. Retry when the other Mac is available."),
                        sourcePanelID: origin.focusedPanelId)
                }
                throw error
            }
        }
    }
}
