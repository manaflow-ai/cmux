import SwiftUI
import Foundation

/// View that renders the appropriate panel view based on panel type
struct PanelContentView: View {
    let panel: any Panel
    let isFocused: Bool
    let isSelectedInPane: Bool
    let isVisibleInUI: Bool
    let isSplit: Bool
    let appearance: PanelAppearance
    let notificationStore: TerminalNotificationStore
    let onFocus: () -> Void
    let onRequestPanelFocus: () -> Void
    let onTriggerFlash: () -> Void

    var body: some View {
        switch panel.panelType {
        case .terminal:
            if let terminalPanel = panel as? TerminalPanel {
                TerminalPanelView(
                    panel: terminalPanel,
                    isFocused: isFocused,
                    isVisibleInUI: isVisibleInUI,
                    isSplit: isSplit,
                    appearance: appearance,
                    notificationStore: notificationStore,
                    onFocus: onFocus,
                    onTriggerFlash: onTriggerFlash
                )
            }
        case .browser:
            if let browserPanel = panel as? BrowserPanel {
                BrowserPanelView(
                    panel: browserPanel,
                    isFocused: isFocused,
                    isVisibleInUI: isVisibleInUI,
                    onRequestPanelFocus: onRequestPanelFocus
                )
            }
        }
    }
}
