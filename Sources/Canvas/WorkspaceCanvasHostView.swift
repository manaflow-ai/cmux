import AppKit
import Bonsplit
import CmuxAppKitSupportUI
import CmuxCanvasUI
import CmuxNotifications
import CmuxSettingsUI

@MainActor
struct WorkspaceCanvasHostConfiguration {
    let workspace: Workspace
    let isWorkspaceVisible: Bool
    let isWorkspaceInputActive: Bool
    let portalPriority: Int
    let appearance: PanelAppearance
    let windowAppearance: WindowAppearanceSnapshot
    let settingsRuntime: SettingsRuntime?
    let sessionContentWidthPresentation: SessionContentWidthPresentation
}

/// Owns the AppKit canvas and projects workspace state into pane descriptors.
/// The parent compatibility boundary remains while the main workspace root
/// is migrated.
@MainActor
final class WorkspaceCanvasHostController: NSViewController {
    private let workspace: Workspace
    private let canvasView: CanvasRootView

    init(configuration: WorkspaceCanvasHostConfiguration) {
        workspace = configuration.workspace
        canvasView = Self.makeCanvasView(workspace: configuration.workspace)
        super.init(nibName: nil, bundle: nil)
        view = canvasView
        update(configuration: configuration)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(configuration: WorkspaceCanvasHostConfiguration) {
        precondition(configuration.workspace === workspace, "Canvas host cannot change workspaces")
        canvasView.sync(
            descriptors: descriptors(configuration: configuration),
            focusedPanelId: workspace.focusedPanelId,
            isWorkspaceVisible: configuration.isWorkspaceVisible
        )
    }

    func teardown() {
        canvasView.teardown()
    }

    private func descriptors(
        configuration: WorkspaceCanvasHostConfiguration
    ) -> [CanvasPaneDescriptor] {
        let focusedPanelId = workspace.focusedPanelId
        let closeActionLabel = String(localized: "canvas.pane.close.help", defaultValue: "Close Pane")
        let isSplit = workspace.orderedPanelIds.count > 1

        return workspace.orderedPanelIds.compactMap { [weak workspace] panelId in
            guard let workspace, let panel = workspace.panels[panelId] else { return nil }
            let isFocused = configuration.isWorkspaceInputActive && focusedPanelId == panelId
            return CanvasPaneDescriptor(
                id: panelId,
                tab: CanvasTabChrome(
                    id: panelId,
                    title: panel.displayTitle,
                    iconSystemName: Self.defaultIcon(for: panel.panelType)
                ),
                isFocused: isFocused,
                closeActionLabel: closeActionLabel,
                makeMount: { [weak workspace] container in
                    CanvasPaneContentMount(
                        content: Self.makeContent(
                            panel: panel,
                            workspace: workspace,
                            pointerInputOwner: container,
                            isFocused: isFocused,
                            isWorkspaceVisible: configuration.isWorkspaceVisible,
                            allowsPointerInput: configuration.isWorkspaceVisible && configuration.isWorkspaceInputActive,
                            portalPriority: configuration.portalPriority,
                            appearance: configuration.appearance,
                            windowAppearance: configuration.windowAppearance,
                            settingsRuntime: configuration.settingsRuntime,
                            sessionContentWidthPresentation: configuration.sessionContentWidthPresentation
                        ),
                        panelId: panelId,
                        container: container,
                        onFocusPanel: { [weak workspace] panelId in
                            workspace?.focusPanel(panelId)
                        }
                    )
                },
                updateMount: { mount in
                    guard let mount = mount as? CanvasPaneContentMount else { return }
                    mount.updatePresentation(
                        isFocused: isFocused,
                        isVisibleInUI: configuration.isWorkspaceVisible,
                        allowsPointerInput: configuration.isWorkspaceVisible && configuration.isWorkspaceInputActive,
                        showsInactiveOverlay: isSplit && !isFocused,
                        inactiveOverlayColor: configuration.appearance.unfocusedOverlayNSColor,
                        inactiveOverlayOpacity: configuration.appearance.unfocusedOverlayOpacity,
                        sessionContentWidthPresentation: configuration.sessionContentWidthPresentation
                    )
                }
            )
        }
    }

    private static func defaultIcon(for panelType: PanelType) -> String {
        switch panelType {
        case .terminal: return "terminal"
        case .browser: return "globe"
        case .markdown: return "doc.richtext"
        case .filePreview: return "doc.text.magnifyingglass"
        case .rightSidebarTool: return "sidebar.right"
        case .customSidebar: return "wand.and.stars"
        case .simulator: return "iphone.gen3"
        case .agentSession: return "sparkles"
        case .project: return "folder"
        case .extensionBrowser: return "puzzlepiece.extension"
        case .workspaceTodo: return "checklist"
        case .cloudVMLoading: return "cloud.fill"
        case .mobilePairing: return "iphone"
        case .accountSignIn: return "person.crop.circle"
        }
    }

    private static func makeContent(
        panel: any Panel,
        workspace: Workspace?,
        pointerInputOwner: NSView,
        isFocused: Bool,
        isWorkspaceVisible: Bool,
        allowsPointerInput: Bool,
        portalPriority: Int,
        appearance: PanelAppearance,
        windowAppearance: WindowAppearanceSnapshot,
        settingsRuntime: SettingsRuntime?,
        sessionContentWidthPresentation: SessionContentWidthPresentation
    ) -> CanvasPaneContent {
        if let terminalPanel = panel as? TerminalPanel {
            return .terminal(terminalPanel, sessionContentWidthPresentation)
        }

        let presentation = CanvasHostedPanelPresentation(
            isFocused: isFocused,
            allowsPointerInput: allowsPointerInput,
            pointerInputOwner: pointerInputOwner
        )
        var panelConfiguration = PanelContentConfiguration(
            panel: panel,
            workspaceID: workspace?.id ?? UUID(),
            paneID: workspace?.bonsplitPaneId(forPanelId: panel.id) ?? PaneID(),
            isFocused: isFocused,
            isSelectedInPane: true,
            isVisibleInUI: isWorkspaceVisible,
            allowsPointerInput: allowsPointerInput,
            pointerEntryEventFilter: presentation.acceptsPointerEntryEvent,
            portalPriority: portalPriority,
            isSplit: false,
            appearance: appearance,
            windowAppearance: windowAppearance,
            customSidebarTabManager: workspace?.owningTabManager,
            customSidebarUnread: TerminalNotificationStore.shared.sidebarUnread,
            hasUnreadNotification: false,
            terminalAgentContext: "",
            paneOwnershipOverride: nil,
            terminalPaneOwnershipResolver: nil,
            paneDropZone: nil,
            onFocus: { [weak workspace] in workspace?.focusPanel(panel.id) },
            onRequestPanelFocus: { [weak workspace] in workspace?.focusPanel(panel.id) },
            onResumeAgentHibernation: {},
            onAutoResumeAgentHibernation: {},
            onTriggerFlash: {}
        )
        panelConfiguration.settingsRuntime = settingsRuntime
        panelConfiguration.canvasInlineBrowserHosting = !UserDefaults.standard.bool(
            forKey: "canvasInlineBrowserHostingDisabled"
        )
        let controller = PanelContentViewController(configuration: panelConfiguration)
        return .hosted(panel, controller, presentation, panelConfiguration)
    }

    private static func makeCanvasView(workspace: Workspace) -> CanvasRootView {
        CanvasRootView(
            model: workspace.canvasModel,
            commandScrollHintText: String(
                localized: "canvas.commandScrollHint",
                defaultValue: "Command+scroll pans the canvas from anywhere"
            ),
            minimapAccessibilityLabel: String(
                localized: "canvas.minimap.accessibilityLabel",
                defaultValue: "Canvas minimap"
            ),
            minimapAccessibilityHelp: String(
                localized: "canvas.minimap.accessibilityHelp",
                defaultValue: "Click or drag to move the canvas viewport"
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
}
