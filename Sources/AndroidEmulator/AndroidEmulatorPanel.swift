import Combine
import CmuxAndroidEmulator
import CmuxAndroidEmulatorUI
import Foundation
import SwiftUI

/// Durable cmux surface that selects and then hosts one Android emulator.
@MainActor
final class AndroidEmulatorPanel: Panel {
    let id: UUID
    let stableSurfaceIdentity = PanelStableSurfaceIdentity()
    let panelType: PanelType = .androidEmulator
    let coordinator: AndroidEmulatorCoordinator
    private(set) var controller: AndroidEmulatorPaneController?
    var onDisplayTitleChange: ((String) -> Void)?
    private var stopConfirmedHandler: (() -> Void)?
    let objectWillChange = ObservableObjectPublisher()

    var displayTitle: String {
        controller?.avdName ?? String(
            localized: "androidEmulator.title",
            defaultValue: "Android Emulators"
        )
    }
    var displayIcon: String? { "apps.iphone" }

    init(
        id: UUID = UUID(),
        coordinator: AndroidEmulatorCoordinator,
        controller: AndroidEmulatorPaneController? = nil
    ) {
        self.id = id
        self.coordinator = coordinator
        self.controller = controller
    }

    var isSelectingDevice: Bool { controller == nil }

    func select(_ device: AndroidVirtualDevice) {
        guard case .loaded(let snapshot) = coordinator.loadState,
              case .running(let serial, _, let transportID) = device.state else { return }
        controller?.closePane()
        objectWillChange.send()
        controller = AndroidEmulatorPaneController(
            avdName: device.name,
            serial: serial,
            transportID: transportID,
            sdkRootURL: snapshot.sdkRootURL,
            coordinator: coordinator
        )
        onDisplayTitleChange?(displayTitle)
        if let stopConfirmedHandler {
            controller?.setStopConfirmedHandler(stopConfirmedHandler)
        }
    }

    func setStopConfirmedHandler(_ handler: @escaping () -> Void) {
        stopConfirmedHandler = handler
        controller?.setStopConfirmedHandler(handler)
    }

    func close() {
        controller?.closePane()
    }

    func focus() {
        controller?.focusCapture()
    }

    func unfocus() {}
    func triggerFlash(reason: WorkspaceAttentionFlashReason) {}
}

struct AndroidEmulatorPanelContentView: View {
    @ObservedObject var panel: AndroidEmulatorPanel
    let isVisible: Bool
    let backgroundColor: Color

    var body: some View {
        Group {
            if let controller = panel.controller {
                AndroidEmulatorPaneView(
                    controller: controller,
                    isVisible: isVisible,
                    backgroundColor: backgroundColor
                )
            } else {
                AndroidEmulatorPickerView(
                    coordinator: panel.coordinator,
                    onOpenInPane: panel.select
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(backgroundColor)
    }
}
