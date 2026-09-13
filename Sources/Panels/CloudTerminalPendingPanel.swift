import Combine
import Foundation

/// A temporary panel that explains a Cloud terminal creation still in flight.
///
/// The panel uses the existing loading surface kind for compatibility with the
/// workspace shell, but is owned by the Cloud terminal creation operation and
/// never participates in Cloud VM startup.
@MainActor
final class CloudTerminalPendingPanel: Panel {
    enum Phase: Equatable {
        case starting
        case failed(String)
    }

    let id = UUID()
    let workspaceId: UUID
    let machine: SurfaceMachineID
    let stableSurfaceIdentity = PanelStableSurfaceIdentity()
    let panelType: PanelType = .cloudVMLoading
    @Published private(set) var phase: Phase = .starting
    private(set) var createdResource: SurfaceResource?
    var onRetry: (() -> Void)?
    var onCancel: (() -> Void)?

    var displayTitle: String {
        String(localized: "cloudTerminal.creation.title", defaultValue: "Cloud Terminal")
    }

    var displayIcon: String? { "terminal.fill" }

    init(workspaceId: UUID, machine: SurfaceMachineID) {
        self.workspaceId = workspaceId
        self.machine = machine
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
        phase = .starting
    }

    func setCreatedResource(_ resource: SurfaceResource) {
        createdResource = resource
    }

    func showFailure(_ detail: String) {
        let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        phase = .failed(trimmed.isEmpty
            ? String(localized: "cloudTerminal.creation.failed.detail", defaultValue: "cmux-tui did not accept the terminal request.")
            : String(trimmed.prefix(600)))
    }

    func retry() {
        onRetry?()
    }
}
