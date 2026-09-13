import Foundation

/// A temporary panel that explains a Cloud terminal creation still in flight.
///
/// The panel uses the existing loading surface kind for compatibility with the
/// workspace shell, but is owned by the Cloud terminal creation operation and
/// never participates in Cloud VM startup.
@MainActor
final class CloudTerminalPendingPanel: Panel {
    let id = UUID()
    let workspaceId: UUID
    let machine: SurfaceMachineID
    let stableSurfaceIdentity = PanelStableSurfaceIdentity()
    let panelType: PanelType = .cloudVMLoading
    let state: CloudTerminalPendingState
    var onRetry: (() -> Void)?
    var onCancel: (() -> Void)?

    var displayTitle: String {
        String(localized: "cloudTerminal.creation.title", defaultValue: "Cloud Terminal")
    }

    var displayIcon: String? { "terminal.fill" }

    init(workspaceId: UUID, machine: SurfaceMachineID) {
        self.workspaceId = workspaceId
        self.machine = machine
        state = CloudTerminalPendingState()
    }

    func close() {
        onCancel?()
        onCancel = nil
        onRetry = nil
    }

    func focus() {}
    func unfocus() {}
    func triggerFlash(reason: WorkspaceAttentionFlashReason) {}

    func resetForRetry() {
        state.resetForRetry()
    }

    func showFailure() {
        state.showFailure()
    }

    func retry() {
        onRetry?()
    }
}
