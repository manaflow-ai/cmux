import SwiftUI
import AppKit
import Bonsplit
import CmuxCanvasUI
import CmuxSettingsUI

/// SwiftUI host for a workspace's canvas layout.
///
/// This is the single legacy-observing boundary: it watches the
/// `ObservableObject` workspace, projects panels into value snapshots
/// (`CanvasPaneDescriptor`), and hands them to the `CmuxCanvasUI` package
/// through an `NSViewRepresentable`. The canvas itself never observes
/// stores, and the package never sees panel types — content crosses the
/// seam as `CanvasPaneContentMount` witnesses.
struct WorkspaceCanvasHostView: View {
    @ObservedObject var workspace: Workspace
    let isWorkspaceVisible: Bool
    let isWorkspaceInputActive: Bool
    let portalPriority: Int
    let appearance: PanelAppearance
    @Environment(\.settingsRuntime) private var settingsRuntime

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
        let closeActionLabel = String(localized: "canvas.pane.close.help", defaultValue: "Close Pane")
        return workspace.orderedPanelIds.compactMap { panelId in
            guard let panel = workspace.panels[panelId] else { return nil }
            return CanvasPaneDescriptor(
                id: panelId,
                tab: CanvasTabChrome(
                    id: panelId,
                    title: panel.displayTitle,
                    iconSystemName: panel.displayIcon ?? Self.defaultIcon(for: panel.panelType)
                ),
                isFocused: isWorkspaceInputActive && focusedPanelId == panelId,
                closeActionLabel: closeActionLabel,
                makeMount: { [weak workspace] container in
                    CanvasPaneContentMount(
                        content: Self.makeContent(
                            panel: panel,
                            workspace: workspace,
                            isWorkspaceVisible: isWorkspaceVisible,
                            portalPriority: portalPriority,
                            appearance: appearance,
                            settingsRuntime: settingsRuntime
                        ),
                        panelId: panelId,
                        container: container,
                        onFocusPanel: { [weak workspace] panelId in
                            workspace?.focusPanel(panelId)
                        }
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
        appearance: PanelAppearance,
        settingsRuntime: SettingsRuntime?
    ) -> CanvasPaneContent {
        if let terminalPanel = panel as? TerminalPanel {
            return .terminal(terminalPanel)
        }
        let workspaceId = workspace?.id ?? UUID()
        let paneId = workspace?.bonsplitPaneId(forPanelId: panel.id) ?? PaneID()
        let content = CanvasHostedPanelContentView(
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
        let hosted = NSHostingView(rootView: AnyView(
            content.environment(\.settingsRuntime, settingsRuntime)
        ))
        // The pane's content container dictates the size; never let the
        // hosting view shrink to SwiftUI's ideal size.
        hosted.sizingOptions = []
        return .hosted(panel, hosted)
    }
}

/// Bridges descriptor snapshots into the package's AppKit canvas.
/// `updateNSView` is the one place SwiftUI state flows into the canvas, so
/// no store observation exists below this point.
private struct CanvasRootRepresentable: NSViewRepresentable {
    let workspace: Workspace
    let descriptors: [CanvasPaneDescriptor]
    let focusedPanelId: UUID?
    let isWorkspaceVisible: Bool

    func makeNSView(context: Context) -> CanvasRootView {
        let workspace = workspace
        return CanvasRootView(
            model: workspace.canvasModel,
            commandScrollHintText: String(
                localized: "canvas.commandScrollHint",
                defaultValue: "Command+scroll pans the canvas from anywhere"
            ),
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
                    guard let workspace else { return }
                    workspace.noteCanvasLayoutChanged()
                    workspace.syncCanvasBrowserPortalZOrder()
                },
                onViewportGeometryChanged: { [weak workspace] window in
                    // Window-portal-hosted content (browser webviews) tracks
                    // anchor geometry; canvas scrolls/zooms/drags move anchors
                    // without any split-layout event. Sync each browser anchor
                    // synchronously so webviews track pane geometry within the
                    // same frame, then schedule the coalesced settle-up pass.
                    if let workspace {
                        for panel in workspace.panels.values {
                            guard let browserPanel = panel as? BrowserPanel,
                                  !browserPanel.canvasInlineHostingActive else { continue }
                            BrowserWindowPortalRegistry.synchronizeForAnchor(browserPanel.portalAnchorView)
                        }
                    }
                    guard let window else { return }
                    BrowserWindowPortalRegistry.scheduleExternalGeometrySynchronize(for: window)
                },
                onViewportSettled: { [weak workspace] window in
                    // Gesture end: force-refresh every portal-hosted browser so
                    // content can never rest at a stale frame, and re-derive
                    // portal z-priorities from canvas z-order so front panes'
                    // webviews stack above back panes'.
                    guard let workspace else { return }
                    let zOrder = workspace.canvasModel.layout.paneIDs
                    for panel in workspace.panels.values {
                        guard let browserPanel = panel as? BrowserPanel,
                              !browserPanel.canvasInlineHostingActive else { continue }
                        if let paneID = workspace.canvasModel.paneID(containing: browserPanel.id),
                           let z = zOrder.firstIndex(of: paneID) {
                            BrowserWindowPortalRegistry.updateEntryVisibility(
                                for: browserPanel.webView,
                                visibleInUI: true,
                                zPriority: 2 + z
                            )
                        }
                        BrowserWindowPortalRegistry.refresh(
                            webView: browserPanel.webView,
                            reason: "canvas.viewportSettled"
                        )
                    }
                    _ = window
                }
            ),
            themeProvider: {
                let background = GhosttyBackgroundTheme.currentColor()
                return CanvasTheme(canvasBackground: background, paneBackground: background)
            }
        )
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
