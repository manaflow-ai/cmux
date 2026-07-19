import CmuxFoundation
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
    let portalPriority: Int
    let isSplit: Bool
    let appearance: PanelAppearance
    let windowAppearance: WindowAppearanceSnapshot
    let customSidebarTabManager: TabManager?
    let customSidebarUnread: SidebarUnreadModel = TerminalNotificationStore.shared.sidebarUnread
    let hasUnreadNotification: Bool
    let terminalAgentContext: String
    /// Explicit browser pane-ownership signal for hosts whose panels live outside
    /// the main `Workspace` tree (the Dock). `nil` keeps the main-area behavior.
    var paneOwnershipOverride: Bool? = nil
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
                    paneOwnershipOverride: paneOwnershipOverride,
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
        case .cloudVMLoading:
            if let loadingPanel = panel as? CloudVMLoadingPanel {
                CloudVMLoadingPanelView(panel: loadingPanel)
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
        case .markdown, .filePreview, .rightSidebarTool, .customSidebar, .agentSession, .project, .extensionBrowser, .workspaceTodo, .cloudVMLoading:
            return true
        case .terminal, .browser:
            return false
        }
    }
}

private struct CloudVMLoadingPanelView: View {
    @ObservedObject var panel: CloudVMLoadingPanel

    var body: some View {
        let schedule: PeriodicTimelineSchedule = .periodic(from: panel.startedAt, by: 1)
        TimelineView(schedule) { context in
            let elapsedSeconds = max(0, Int(context.date.timeIntervalSince(panel.startedAt).rounded(.down)))
            VStack(spacing: 14) {
                switch panel.phase {
                case .loading:
                    ProgressView()
                        .controlSize(.small)
                    Text(String(localized: "panel.cloudVM.loading.headline", defaultValue: "Opening Base"))
                        .cmuxFont(size: 14, weight: .semibold)
                        .foregroundStyle(.primary)
                    CloudVMLoadingStatusView(elapsedSeconds: elapsedSeconds)
                case .failed(let message, let failedElapsedSeconds):
                    CmuxSystemSymbolImage(systemName: "exclamationmark.triangle.fill", pointSize: 18)
                        .foregroundStyle(.orange)
                    Text(String(localized: "panel.cloudVM.loading.failed.headline", defaultValue: "Base unavailable"))
                        .cmuxFont(size: 14, weight: .semibold)
                        .foregroundStyle(.primary)
                    Text(message)
                        .cmuxFont(size: 12)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 460)
                    HStack(spacing: 8) {
                        Button {
                            _ = AppDelegate.shared?.performCloudVMAction(debugSource: "panel.cloudVM.retry")
                        } label: {
                            Label(
                                String(localized: "panel.cloudVM.loading.failed.retry", defaultValue: "Retry"),
                                systemImage: "arrow.clockwise"
                            )
                            .cmuxFont(size: 12, weight: .semibold)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)

                        Button {
                            FeedbackComposerBridge().openComposer()
                        } label: {
                            Label(
                                String(localized: "panel.cloudVM.loading.failed.feedback", defaultValue: "Send Feedback"),
                                systemImage: "bubble.left.and.text.bubble.right"
                            )
                            .cmuxFont(size: 12, weight: .semibold)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    Text(String(format: String(
                        localized: "panel.cloudVM.loading.failed.elapsed",
                        defaultValue: "Waited %ds before stopping."
                    ), failedElapsedSeconds))
                    .cmuxFont(size: 11)
                    .foregroundStyle(.tertiary)
                }
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: GhosttyApp.shared.defaultBackgroundColor))
        }
    }
}

private struct CloudVMLoadingStatusView: View {
    let elapsedSeconds: Int

    var body: some View {
        VStack(spacing: 10) {
            Text(String(format: String(
                localized: "panel.cloudVM.loading.elapsed",
                defaultValue: "%ds elapsed"
            ), elapsedSeconds))
            .cmuxFont(size: 12, weight: .medium)
            .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                CloudVMLoadingStatusRow(
                    icon: "checkmark.circle.fill",
                    text: String(localized: "panel.cloudVM.loading.step.workspace", defaultValue: "Pinned workspace created"),
                    isActive: false
                )
                CloudVMLoadingStatusRow(
                    icon: statusIcon(for: 0..<6),
                    text: statusText,
                    isActive: true
                )
                CloudVMLoadingStatusRow(
                    icon: elapsedSeconds >= 6 ? "arrow.triangle.2.circlepath" : "circle",
                    text: String(localized: "panel.cloudVM.loading.step.terminal", defaultValue: "Terminal will open automatically when ready"),
                    isActive: elapsedSeconds >= 6
                )
            }
            .frame(maxWidth: 420, alignment: .leading)
        }
    }

    private var statusText: String {
        switch elapsedSeconds {
        case 0..<3:
            return String(localized: "panel.cloudVM.loading.step.request", defaultValue: "Requesting your persistent VM")
        case 3..<8:
            return String(localized: "panel.cloudVM.loading.step.resume", defaultValue: "Starting or resuming the VM")
        case 8..<18:
            return String(localized: "panel.cloudVM.loading.step.endpoint", defaultValue: "Waiting for a secure terminal endpoint")
        default:
            return String(localized: "panel.cloudVM.loading.step.retrying", defaultValue: "Still waiting; retrying in the background")
        }
    }

    private func statusIcon(for range: Range<Int>) -> String {
        range.contains(elapsedSeconds) ? "arrow.triangle.2.circlepath" : "checkmark.circle.fill"
    }
}

private struct CloudVMLoadingStatusRow: View {
    let icon: String
    let text: String
    let isActive: Bool

    var body: some View {
        HStack(spacing: 8) {
            CmuxSystemSymbolImage(systemName: icon, pointSize: 12)
                .foregroundStyle(isActive ? .secondary : .tertiary)
                .frame(width: 14)
            Text(text)
                .cmuxFont(size: 12)
                .foregroundStyle(isActive ? .secondary : .tertiary)
                .lineLimit(2)
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
            CmuxSystemSymbolImage(systemName: iconSystemName, pointSize: 16)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(filePath)
                .cmuxFont(size: 11, design: .monospaced)
                .foregroundStyle(Color(nsColor: foregroundColor).opacity(0.68))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
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
        CmuxSystemSymbolImage(systemName: systemName, pointSize: 13)
            .frame(width: 20, height: 20, alignment: .center)
            .contentShape(Rectangle())
    }
}
