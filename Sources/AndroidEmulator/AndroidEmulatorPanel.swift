import Combine
import CmuxAndroidEmulatorUI
import Foundation

/// Durable cmux surface for one transport-bound Android emulator.
@MainActor
final class AndroidEmulatorPanel: Panel {
    let id: UUID
    let stableSurfaceIdentity = PanelStableSurfaceIdentity()
    let panelType: PanelType = .androidEmulator
    let controller: AndroidEmulatorPaneController
    let objectWillChange = ObservableObjectPublisher()

    var displayTitle: String { controller.avdName }
    var displayIcon: String? { "apps.iphone" }

    init(id: UUID = UUID(), controller: AndroidEmulatorPaneController) {
        self.id = id
        self.controller = controller
    }

    func close() {
        controller.closePane()
    }

    func focus() {
        controller.focusCapture()
    }

    func unfocus() {}
    func triggerFlash(reason: WorkspaceAttentionFlashReason) {}
}
