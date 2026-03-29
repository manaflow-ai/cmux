import SwiftUI
import Foundation
import Bonsplit

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
        panelContent
            .overlay {
                // Focus ring: thin accent-colored border shown only when this pane is focused
                // and there are multiple panes. SwiftUI-only — never touches AppKit layers.
                // allowsHitTesting(false) ensures the ring never intercepts pointer events.
                FocusRingView(isVisible: isFocused && isSplit)
            }
    }

    private struct FocusRingView: View {
        let isVisible: Bool

        var body: some View {
            Rectangle()
                .strokeBorder(Color.accentColor, lineWidth: 2)
                .opacity(isVisible ? 1 : 0)
                .animation(.easeInOut(duration: 0.15), value: isVisible)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var panelContent: some View {
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
        }
    }
}
