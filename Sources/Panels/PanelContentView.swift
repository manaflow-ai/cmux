import CmuxFoundation
import CmuxNotifications
import SwiftUI
import Foundation
import Bonsplit
import AppKit
import CmuxAppKitSupportUI
import CmuxFeedback

/// View that renders the appropriate panel view based on panel type
struct PanelContentView: View {
    let panel: any Panel
    let workspaceId: UUID
    let paneId: PaneID
    let isFocused: Bool
    let isSelectedInPane: Bool
    let isVisibleInUI: Bool
    let allowsPointerInput: Bool
    var pointerEntryEventFilter: (@MainActor (NSEvent) -> Bool)? = nil
    let portalPriority: Int
    let isSplit: Bool
    let appearance: PanelAppearance
    let windowAppearance: WindowAppearanceSnapshot
    let customSidebarTabManager: TabManager?
    let customSidebarUnread: SidebarUnreadModel = TerminalNotificationStore.shared.sidebarUnread
    let hasUnreadNotification: Bool
    let terminalAgentContext: String
    /// Appearance inherited from the host before this view injects the
    /// surface-resolved scheme for its rendered panel subtree. Browser WebKit
    /// system theming may observe this value; browser chrome must not.
    @Environment(\.colorScheme) private var inheritedColorScheme
    /// Explicit browser pane-ownership signal for hosts whose panels live outside
    /// the main `Workspace` tree (the Dock). `nil` keeps the main-area behavior.
    var paneOwnershipOverride: Bool? = nil
    /// Live terminal pane ownership. Portal callbacks invoke this again instead
    /// of trusting the SwiftUI snapshot captured before a cross-container move.
    var terminalPaneOwnershipResolver: (@MainActor () -> Bool)? = nil
    let onFocus: () -> Void
    let onRequestPanelFocus: () -> Void
    let onResumeAgentHibernation: () -> Void
    let onAutoResumeAgentHibernation: () -> Void
    let onTriggerFlash: () -> Void
    /// Owner action used to materialize a deferred browser after its host reports visibility.
    let onRequestDeferredBrowserMaterialization: () -> Void

    var body: some View {
        renderedPanel
            .environment(\.colorScheme, windowAppearance.resolvedColorScheme)
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
                    portalPaneOwnershipResolver: terminalPaneOwnershipResolver,
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
            } else {
                TerminalPanelUnavailableView(appearance: appearance)
            }
        case .browser:
            if let browserPanel = panel as? BrowserPanel {
                BrowserPanelView(
                    panel: browserPanel,
                    paneId: paneId,
                    isFocused: isFocused,
                    isVisibleInUI: isVisibleInUI,
                    portalPriority: portalPriority,
                    paneOwnershipOverride: paneOwnershipOverride,
                    resolvedColorScheme: windowAppearance.resolvedColorScheme,
                    inheritedColorScheme: inheritedColorScheme,
                    resolvedThemeBackgroundColor: windowAppearance.resolvedChromeBackgroundColor,
                    onRequestPanelFocus: onRequestPanelFocus
                )
                // Browser chrome owns panel-scoped edit/focus state. Bonsplit reuses this
                // structural slot when a pane selects another browser, so bind its lifetime
                // to the panel instead of carrying the prior panel's omnibar draft forward.
                .id(browserPanel.id)
            } else if panel is DeferredBrowserPanel {
                DeferredBrowserPanelView(
                    isVisibleInUI: isVisibleInUI,
                    onRequestMaterialization: onRequestDeferredBrowserMaterialization,
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
                    resolvedChromeBackgroundColor: windowAppearance.resolvedChromeBackgroundColor,
                    onRequestPanelFocus: onRequestPanelFocus
                )
            }
        case .customSidebar:
            if let customSidebarPanel = panel as? CustomSidebarPanel {
                if let customSidebarTabManager {
                    CustomSidebarPanelView(
                        panel: customSidebarPanel,
                        tabManager: customSidebarTabManager,
                        sidebarUnread: customSidebarUnread,
                        isFocused: isFocused,
                        isVisibleInUI: isVisibleInUI,
                        appearance: appearance,
                        windowAppearance: windowAppearance,
                        onRequestPanelFocus: onRequestPanelFocus
                    )
                }
            }
        case .simulator:
            if let simulatorPanel = panel as? SimulatorPanel {
                if CmuxFeatureFlags.shared.isSimulatorEnabled,
                   simulatorPanel.isFeatureReady {
                    SimulatorPanelView(
                        panel: simulatorPanel,
                        isFocused: isFocused,
                        isVisibleInUI: isVisibleInUI,
                        allowsPointerInput: allowsPointerInput,
                        pointerEntryEventFilter: pointerEntryEventFilter,
                        appearance: appearance,
                        onRequestPanelFocus: onRequestPanelFocus
                    )
                } else {
                    SimulatorFeatureDisabledView(
                        panel: simulatorPanel,
                        appearance: appearance
                    )
                }
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
        case .workspaceTodo:
            if let workspaceTodoPanel = panel as? WorkspaceTodoPanel {
                WorkspaceTodoPanelView(
                    panel: workspaceTodoPanel,
                    isFocused: isFocused,
                    onRequestPanelFocus: onRequestPanelFocus
                )
            }
        case .notifications:
            if panel is NotificationsPanel {
                NotificationsPage(
                    isFocused: isFocused,
                    isVisibleInUI: isVisibleInUI
                )
                    .contentShape(Rectangle())
                    .onTapGesture { onRequestPanelFocus() }
            }
        case .cloudVMLoading:
            if let pendingPanel = panel as? CloudTerminalPendingPanel {
                CloudTerminalPendingPanelView(panel: pendingPanel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let loadingPanel = panel as? CloudVMLoadingPanel {
                CloudVMLoadingPanelView(panel: loadingPanel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .mobilePairing:
            if panel is MobilePairingPanel {
                MobilePairingPanelView(
                    appearance: appearance,
                    onRequestPanelFocus: onRequestPanelFocus
                )
            }
        case .accountSignIn:
            if let accountSignInPanel = panel as? AccountSignInPanel {
                AccountSignInPanelView(
                    panel: accountSignInPanel,
                    appearance: appearance,
                    onRequestPanelFocus: onRequestPanelFocus
                )
            }
        case .cloudVPNSetup:
            if let vpnPanel = panel as? CloudVPNSetupPanel {
                CloudVPNSetupPanelView(
                    appearance: appearance,
                    onRequestPanelFocus: onRequestPanelFocus,
                    model: vpnPanel.model
                )
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
        case .markdown, .filePreview, .rightSidebarTool, .customSidebar, .simulator, .agentSession, .project, .extensionBrowser, .workspaceTodo, .notifications, .cloudVMLoading, .mobilePairing, .accountSignIn, .cloudVPNSetup:
            return true
        case .terminal, .browser:
            return false
        }
    }
}



struct PanelFilePathHeader<TrailingContent: View>: View {
    let iconSystemName: String
    let filePath: String
    let foregroundColor: NSColor
    @ViewBuilder let trailingContent: () -> TrailingContent

    var body: some View {
        HStack(spacing: 8) {
            CmuxSystemSymbolImage(systemName: iconSystemName, pointSize: 16, tint: .secondary)
                .frame(width: 16)
            Text(filePath)
                .cmuxFont(size: 11, design: .monospaced)
                .foregroundStyle(Color(nsColor: foregroundColor).opacity(0.68))
                .lineLimit(1)
                .truncationMode(.middle)
                .copyOnlyTextSelection(for: filePath)
            Spacer(minLength: 8)
            trailingContent()
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(Color.clear)
    }
}

struct PanelHeaderIconButton: View {
    let systemName: String
    let label: String
    var isDisabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            PanelHeaderIconGlyph(systemName: systemName)
        }
        .buttonStyle(.plain)
        .foregroundColor(.secondary)
        .disabled(isDisabled)
        .help(label)
        .accessibilityLabel(label)
    }
}

struct PanelHeaderIconGlyph: View {
    let systemName: String

    var body: some View {
        CmuxSystemSymbolImage(systemName: systemName, pointSize: 13, tint: .secondary)
            .frame(width: 20, height: 20, alignment: .center)
            .contentShape(Rectangle())
    }
}
