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
    let onFocus: () -> Void
    let onRequestPanelFocus: () -> Void
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
        case .markdown, .filePreview, .rightSidebarTool:
            return true
        case .terminal, .browser:
            return false
        }
    }
}

struct PanelFilePathHeader<TrailingContent: View>: View {
    @Environment(\.uiScaleFactor) private var uiScaleFactor

    let iconSystemName: String
    let filePath: String
    let foregroundColor: NSColor
    @ViewBuilder let trailingContent: () -> TrailingContent

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: iconSystemName)
                .foregroundStyle(.secondary)
                .font(.system(size: UIScaleSettings.scaled(12, by: uiScaleFactor)))
                .frame(width: UIScaleSettings.scaled(16, by: uiScaleFactor))
            Text(filePath)
                .font(.system(size: UIScaleSettings.scaled(11, by: uiScaleFactor), design: .monospaced))
                .foregroundStyle(Color(nsColor: foregroundColor).opacity(0.68))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: UIScaleSettings.scaled(8, by: uiScaleFactor))
            trailingContent()
        }
        .padding(.horizontal, UIScaleSettings.scaled(12, by: uiScaleFactor))
        .frame(height: UIScaleSettings.scaled(30, by: uiScaleFactor))
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
    @Environment(\.uiScaleFactor) private var uiScaleFactor

    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .resizable()
            .scaledToFit()
            .frame(
                width: UIScaleSettings.scaled(13, by: uiScaleFactor),
                height: UIScaleSettings.scaled(13, by: uiScaleFactor)
            )
            .frame(
                width: UIScaleSettings.scaled(20, by: uiScaleFactor),
                height: UIScaleSettings.scaled(20, by: uiScaleFactor),
                alignment: .center
            )
            .contentShape(Rectangle())
    }
}
