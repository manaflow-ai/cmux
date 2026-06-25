import CmuxPanes
import SwiftUI
import Foundation
import Bonsplit
import AppKit

/// View that renders the appropriate panel view based on panel type
struct PanelContentView: View {
    let panel: any Panel
    let workspaceId: UUID
    let paneId: PaneID
    let isFocused: Bool
    let isSelectedInPane: Bool
    let isVisibleInUI: Bool
    let portalPriority: Int
    let isSplit: Bool
    let appearance: PanelAppearance
    let hasUnreadNotification: Bool
    let terminalAgentContext: String
    let onFocus: () -> Void
    let onRequestPanelFocus: () -> Void
    let onResumeAgentHibernation: () -> Void
    let onAutoResumeAgentHibernation: () -> Void
    let onTriggerFlash: () -> Void

    var body: some View {
        renderedPanel
            .overlay {
                paneDropTargetOverlay
            }
    }

    @ViewBuilder
    private var renderedPanel: some View {
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
                    terminalAgentContext: terminalAgentContext,
                    onFocus: onFocus,
                    onResumeAgentHibernation: onResumeAgentHibernation,
                    onAutoResumeAgentHibernation: onAutoResumeAgentHibernation,
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
                    appearance: appearance,
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
                    appearance: appearance,
                    onRequestPanelFocus: onRequestPanelFocus
                )
            }
        case .rightSidebarTool:
            if let rightSidebarToolPanel = panel as? RightSidebarToolPanel {
                RightSidebarToolPanelView(
                    panel: rightSidebarToolPanel,
                    isFocused: isFocused,
                    isVisibleInUI: isVisibleInUI,
                    appearance: appearance,
                    onRequestPanelFocus: onRequestPanelFocus
                )
            }
        case .agentSession:
            if let agentSessionPanel = panel as? AgentSessionPanel {
                AgentSessionPanelView(
                    panel: agentSessionPanel,
                    isFocused: isFocused,
                    isVisibleInUI: isVisibleInUI,
                    portalPriority: portalPriority,
                    appearance: appearance,
                    onRequestPanelFocus: onRequestPanelFocus
                )
            }
        case .project:
            if let projectPanel = panel as? ProjectPanel {
                ProjectPanelView(
                    panel: projectPanel,
                    isFocused: isFocused,
                    onRequestPanelFocus: onRequestPanelFocus
                )
            }
        case .extensionBrowser:
            if let extensionBrowserPanel = panel as? CMUXSidebarExtensionBrowserPanel {
                CMUXSidebarExtensionBrowserPanelView(
                    panel: extensionBrowserPanel,
                    onRequestPanelFocus: onRequestPanelFocus
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder
    private var paneDropTargetOverlay: some View {
        if shouldInstallPaneDropTarget {
            PaneDropTargetRepresentable(dropContext: PaneDropContext(
                workspaceId: workspaceId,
                panelId: panel.id,
                paneId: paneId
            ))
        }
    }

    private var shouldInstallPaneDropTarget: Bool {
        guard isVisibleInUI else { return false }
        switch panel.panelType {
        case .markdown, .filePreview, .rightSidebarTool, .agentSession, .project, .extensionBrowser:
            return true
        case .terminal, .browser:
            return false
        }
    }
}
