import AppKit
import Combine
import Foundation

/// Ephemeral panel that hosts the iOS Simulator viewer in a bonsplit pane.
/// Holds an optional preferred UDID so the view auto-selects on appear.
@MainActor
final class SimulatorPanel: Panel, ObservableObject {
    let id: UUID
    let panelType: PanelType = .simulator

    private(set) var workspaceId: UUID

    @Published private(set) var displayTitle: String
    @Published private(set) var preferredUDID: String?
    @Published private(set) var focusFlashToken: Int = 0

    var displayIcon: String? { "iphone" }

    init(workspaceId: UUID, preferredUDID: String? = nil, title: String? = nil) {
        self.id = UUID()
        self.workspaceId = workspaceId
        self.preferredUDID = preferredUDID
        self.displayTitle = title ?? String(localized: "simulator.window.title", defaultValue: "iOS Simulators")
    }

    // MARK: - Panel protocol

    func focus() {}
    func unfocus() {}

    func close() {}

    func triggerFlash(reason: WorkspaceAttentionFlashReason) {
        _ = reason
        focusFlashToken += 1
    }

    func setPreferredUDID(_ udid: String?) {
        preferredUDID = udid
    }

    func setTitle(_ newTitle: String) {
        displayTitle = newTitle
    }
}
