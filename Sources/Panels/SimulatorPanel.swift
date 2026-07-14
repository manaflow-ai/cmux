import AppKit
import Combine
import CmuxSimulator
import Foundation

/// A pane that shows one iOS Simulator device's live display.
///
/// All simulator behavior lives on ``SimulatorPaneModel`` (in the
/// `CmuxSimulator` package); this class is only the `Panel`-protocol adapter
/// that hosts the model inside the workspace pane system. Closing the pane
/// tears the model down, which shuts the device down only when cmux booted it
/// (never a device the user or another tool booted).
@MainActor
final class SimulatorPanel: Panel, ObservableObject {
    let id: UUID
    let stableSurfaceIdentity = PanelStableSurfaceIdentity()
    let panelType: PanelType = .simulator

    /// The owning workspace's identifier.
    let workspaceId: UUID

    /// The observable simulator pipeline this pane renders.
    let model: SimulatorPaneModel

    var displayTitle: String {
        String(localized: "simulatorPane.title", defaultValue: "Simulator")
    }

    var displayIcon: String? { "iphone" }

    /// Token incremented to trigger the focus flash animation.
    @Published private(set) var focusFlashToken: Int = 0

    init(workspaceId: UUID, deviceQuery: String) {
        self.id = UUID()
        self.workspaceId = workspaceId
        self.model = SimulatorPaneModel(deviceQuery: deviceQuery)
        model.start()
    }

    // MARK: - Panel protocol

    func focus() {
        // The pane is display chrome; no dedicated first responder in v1
        // (input forwarding is deferred, see the CmuxSimulator README).
    }

    func unfocus() {}

    func close() {
        model.closePane()
    }

    func triggerFlash(reason: WorkspaceAttentionFlashReason) {
        _ = reason
        guard NotificationPaneFlashSettings.isEnabled() else { return }
        focusFlashToken += 1
    }
}
