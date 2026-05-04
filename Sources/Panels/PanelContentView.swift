import SwiftUI
import Foundation
import Bonsplit
import CMUXSimulator

/// View that renders the appropriate panel view based on panel type
struct PanelContentView: View {
    let panel: any Panel
    let paneId: PaneID
    let isFocused: Bool
    let isSelectedInPane: Bool
    let isVisibleInUI: Bool
    let portalPriority: Int
    let isSplit: Bool
    let appearance: PanelAppearance
    let hasUnreadNotification: Bool
    let onFocus: () -> Void
    let onRequestPanelFocus: () -> Void
    let onTriggerFlash: () -> Void

    var body: some View {
        switch panel.panelType {
        case .terminal:
            if let terminalPanel = panel as? TerminalPanel {
                TerminalPanelView(
                    panel: terminalPanel,
                    paneId: paneId,
                    isFocused: isFocused,
                    isVisibleInUI: isVisibleInUI,
                    portalPriority: portalPriority,
                    isSplit: isSplit,
                    appearance: appearance,
                    hasUnreadNotification: hasUnreadNotification,
                    onFocus: onFocus,
                    onTriggerFlash: onTriggerFlash
                )
            }
        case .browser:
            if let browserPanel = panel as? BrowserPanel {
                BrowserPanelView(
                    panel: browserPanel,
                    paneId: paneId,
                    isFocused: isFocused,
                    isVisibleInUI: isVisibleInUI,
                    portalPriority: portalPriority,
                    onRequestPanelFocus: onRequestPanelFocus
                )
            }
        case .markdown:
            if let markdownPanel = panel as? MarkdownPanel {
                MarkdownPanelView(
                    panel: markdownPanel,
                    isFocused: isFocused,
                    isVisibleInUI: isVisibleInUI,
                    portalPriority: portalPriority,
                    onRequestPanelFocus: onRequestPanelFocus
                )
            }
        case .filePreview:
            if let filePreviewPanel = panel as? FilePreviewPanel {
                FilePreviewPanelView(
                    panel: filePreviewPanel,
                    isFocused: isFocused,
                    isVisibleInUI: isVisibleInUI,
                    portalPriority: portalPriority,
                    onRequestPanelFocus: onRequestPanelFocus
                )
            }
        case .simulator:
            if let simulatorPanel = panel as? SimulatorPanel {
                SimulatorPanelView(
                    panel: simulatorPanel,
                    onRequestPanelFocus: onRequestPanelFocus
                )
            }
        }
    }
}

@MainActor
final class SimulatorPanel: Panel, ObservableObject {
    let id: UUID
    let panelType: PanelType = .simulator
    private(set) var workspaceId: UUID
    @Published private(set) var deviceUDID: String?
    @Published private(set) var displayTitle: String
    @Published private(set) var focusFlashToken: Int = 0

    var displayIcon: String? { "iphone" }

    init(workspaceId: UUID, deviceUDID: String? = nil) {
        id = UUID()
        self.workspaceId = workspaceId
        self.deviceUDID = deviceUDID
        let baseTitle = String(localized: "simulator.panel.title", defaultValue: "Simulator")
        displayTitle = deviceUDID.map { "\(baseTitle) \($0.prefix(8))" } ?? baseTitle
    }

    func selectDevice(_ device: CMUXSimulatorDevice) {
        deviceUDID = device.udid
        displayTitle = device.name
    }

    func close() {}

    func focus() {}

    func unfocus() {}

    func triggerFlash(reason: WorkspaceAttentionFlashReason) {
        _ = reason
        guard NotificationPaneFlashSettings.isEnabled() else { return }
        focusFlashToken += 1
    }
}

private struct SimulatorPanelView: View {
    @ObservedObject var panel: SimulatorPanel
    let onRequestPanelFocus: () -> Void

    var body: some View {
        CMUXSimulatorViewer(
            initialUDID: panel.deviceUDID,
            onDeviceSelected: { device in
                Task { @MainActor in
                    panel.selectDevice(device)
                    onRequestPanelFocus()
                }
            }
        )
        .onTapGesture {
            onRequestPanelFocus()
        }
        .focusable()
    }
}
