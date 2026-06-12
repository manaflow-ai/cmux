import SwiftUI
import AppKit
import Bonsplit

/// SwiftUI host for a workspace's canvas layout.
///
/// This is the single legacy-observing boundary: it watches the
/// `ObservableObject` workspace, projects panels into value snapshots
/// (`CanvasPaneDescriptor`), and hands them to the AppKit canvas through an
/// `NSViewRepresentable`. The canvas itself never observes stores.
struct WorkspaceCanvasHostView: View {
    @ObservedObject var workspace: Workspace
    let isWorkspaceVisible: Bool
    let isWorkspaceInputActive: Bool
    let portalPriority: Int
    let appearance: PanelAppearance

    var body: some View {
        CanvasRootRepresentable(
            workspace: workspace,
            descriptors: descriptors,
            focusedPanelId: workspace.focusedPanelId,
            isWorkspaceVisible: isWorkspaceVisible
        )
    }

    private var descriptors: [CanvasPaneDescriptor] {
        let focusedPanelId = workspace.focusedPanelId
        return workspace.orderedPanelIds.compactMap { panelId in
            guard let panel = workspace.panels[panelId] else { return nil }
            return CanvasPaneDescriptor(
                id: panelId,
                title: panel.displayTitle,
                iconSystemName: panel.displayIcon ?? Self.defaultIcon(for: panel.panelType),
                isFocused: isWorkspaceInputActive && focusedPanelId == panelId,
                makeContent: { [weak workspace] in
                    Self.makeContent(
                        panel: panel,
                        workspace: workspace,
                        isWorkspaceVisible: isWorkspaceVisible,
                        portalPriority: portalPriority,
                        appearance: appearance
                    )
                }
            )
        }
    }

    static func defaultIcon(for panelType: PanelType) -> String {
        switch panelType {
        case .terminal: return "terminal"
        case .browser: return "globe"
        case .markdown: return "doc.richtext"
        case .filePreview: return "doc.text.magnifyingglass"
        case .rightSidebarTool: return "sidebar.right"
        case .agentSession: return "sparkles"
        case .project: return "folder"
        case .extensionBrowser: return "puzzlepiece.extension"
        }
    }

    @MainActor
    private static func makeContent(
        panel: any Panel,
        workspace: Workspace?,
        isWorkspaceVisible: Bool,
        portalPriority: Int,
        appearance: PanelAppearance
    ) -> CanvasPaneContent {
        if let terminalPanel = panel as? TerminalPanel {
            return .terminal(terminalPanel)
        }
        let workspaceId = workspace?.id ?? UUID()
        let paneId = workspace?.bonsplitPaneId(forPanelId: panel.id) ?? PaneID()
        let hosted = NSHostingView(rootView: AnyView(
            CanvasHostedPanelContentView(
                panel: panel,
                workspaceId: workspaceId,
                paneId: paneId,
                isFocused: false,
                isVisibleInUI: isWorkspaceVisible,
                portalPriority: portalPriority,
                appearance: appearance,
                onRequestPanelFocus: { [weak workspace] in
                    workspace?.focusPanel(panel.id)
                }
            )
        ))
        return .hosted(hosted)
    }
}

/// Bridges descriptor snapshots into the AppKit canvas. `updateNSView` is the
/// one place SwiftUI state flows into the canvas, so no store observation
/// exists below this point.
private struct CanvasRootRepresentable: NSViewRepresentable {
    let workspace: Workspace
    let descriptors: [CanvasPaneDescriptor]
    let focusedPanelId: UUID?
    let isWorkspaceVisible: Bool

    func makeNSView(context: Context) -> CanvasRootView {
        let workspace = workspace
        let view = CanvasRootView(
            model: workspace.canvasModel,
            callbacks: CanvasHostCallbacks(
                onFocusPanel: { [weak workspace] panelId in
                    guard let workspace else { return }
                    AppDelegate.shared?.noteMainPanelKeyboardFocusIntent(
                        workspaceId: workspace.id,
                        panelId: panelId,
                        in: NSApp.keyWindow ?? NSApp.mainWindow
                    )
                    workspace.focusPanel(panelId)
                },
                onClosePanel: { [weak workspace] panelId in
                    _ = workspace?.closePanel(panelId)
                },
                onLayoutChanged: { [weak workspace] in
                    workspace?.noteCanvasLayoutChanged()
                }
            )
        )
        return view
    }

    func updateNSView(_ nsView: CanvasRootView, context: Context) {
        nsView.sync(
            descriptors: descriptors,
            focusedPanelId: focusedPanelId,
            isWorkspaceVisible: isWorkspaceVisible
        )
    }

    static func dismantleNSView(_ nsView: CanvasRootView, coordinator: ()) {
        nsView.teardown()
    }
}
