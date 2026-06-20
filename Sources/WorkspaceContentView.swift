import SwiftUI
import Foundation
import AppKit
import CmuxAppKitSupportUI
import CmuxFoundation
import Bonsplit
import CmuxWorkspaces
import CmuxTerminal

enum TmuxOverlayExperimentTarget: String, CaseIterable, Codable, Sendable {
    case surface
    case bonsplitPane
    case tmuxActivePane

    var usesWorkspacePaneOverlay: Bool {
        self == .bonsplitPane
    }

    var usesTmuxActivePaneOverlay: Bool {
        self == .tmuxActivePane
    }
}

struct TmuxOverlayExperimentSettings {
    static let enabledKey = "tmuxOverlayExperimentEnabled"
    static let targetKey = "tmuxOverlayExperimentTarget"
    static let defaultEnabled = false
    static let defaultTarget: TmuxOverlayExperimentTarget = .surface

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? defaultEnabled
    }

    static func target(defaults: UserDefaults = .standard) -> TmuxOverlayExperimentTarget {
        target(
            enabled: isEnabled(defaults: defaults),
            rawValue: defaults.string(forKey: targetKey)
        )
    }

    static func target(enabled: Bool, rawValue: String?) -> TmuxOverlayExperimentTarget {
        guard enabled else { return .surface }
        guard let rawValue,
              let target = TmuxOverlayExperimentTarget(rawValue: rawValue) else {
            return defaultTarget
        }
        return target
    }
}

private enum WorkspaceTitlebarInteractionMetrics {
    // Keep in sync with the minimal-mode titlebar strip so the monitor only
    // covers titlebar chrome.
    static let minimalModeTopStripHeight: CGFloat = MinimalModeChromeMetrics.titlebarHeight
}

struct TmuxWorkspacePaneOverlayRenderState: Equatable {
    let workspaceId: UUID
    let unreadRects: [CGRect]
    let flashRect: CGRect?
    let flashToken: UInt64
    let flashReason: WorkspaceAttentionFlashReason?
}

@MainActor
final class TmuxWorkspacePaneOverlayModel: ObservableObject {
    @Published private(set) var unreadRects: [CGRect] = []
    @Published private(set) var flashRect: CGRect?
    @Published private(set) var flashStartedAt: Date?
    @Published private(set) var flashReason: WorkspaceAttentionFlashReason?

    private var currentWorkspaceId: UUID?
    private var lastFlashTokenByWorkspaceId: [UUID: UInt64] = [:]

    func apply(
        _ state: TmuxWorkspacePaneOverlayRenderState,
        now: () -> Date = Date.init
    ) {
        unreadRects = state.unreadRects
        flashRect = state.flashRect
        flashReason = state.flashReason

        let didChangeWorkspace = currentWorkspaceId != state.workspaceId
        let previousFlashToken = lastFlashTokenByWorkspaceId[state.workspaceId]
        let didChangeFlashToken = previousFlashToken.map { state.flashToken != $0 } ?? (state.flashToken > 0)
        if didChangeFlashToken,
           state.flashRect != nil {
            flashStartedAt = now()
        } else if didChangeWorkspace {
            flashStartedAt = nil
        }
        currentWorkspaceId = state.workspaceId
        if (previousFlashToken == nil && state.flashToken == 0) ||
            !didChangeFlashToken ||
            state.flashRect != nil {
            lastFlashTokenByWorkspaceId[state.workspaceId] = state.flashToken
        }
    }

    func clear() {
        unreadRects = []
        flashRect = nil
        flashStartedAt = nil
        flashReason = nil
        currentWorkspaceId = nil
        lastFlashTokenByWorkspaceId = [:]
    }
}

/// View that renders a Workspace's content using BonsplitView
struct WorkspaceContentView: View {
    private struct DeferredThemeRefresh {
        let reason: String
        let backgroundOverride: NSColor?
        let backgroundEventId: UInt64?
        let backgroundSource: String?
        let notificationPayloadHex: String?
        let forceInitialApply: Bool
    }

    @ObservedObject var workspace: Workspace
    let isWorkspaceVisible: Bool
    let isWorkspaceInputActive: Bool
    let isFullScreen: Bool
    let workspacePortalPriority: Int
    let windowAppearance: WindowAppearanceSnapshot
    let onThemeRefreshRequest: ((
        _ reason: String,
        _ backgroundEventId: UInt64?,
        _ backgroundSource: String?,
        _ notificationPayloadHex: String?
    ) -> Void)?
    @State private var config = WorkspaceContentView.resolveGhosttyAppearanceConfig(reason: "stateInit")
    @State private var lastAppliedUsesHostLayerBackground = GhosttyApp.shared.usesHostLayerBackground
    @State private var deferredThemeRefresh: DeferredThemeRefresh?
    @AppStorage(WorkspacePresentationModeSettings.modeKey)
    private var workspacePresentationMode = WorkspacePresentationModeSettings.defaultMode.rawValue
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject var notificationStore: TerminalNotificationStore

    private var isMinimalMode: Bool { WorkspacePresentationModeSettings.mode(for: workspacePresentationMode) == .minimal }

    static func panelVisibleInUI(
        isWorkspaceVisible: Bool,
        isSelectedInPane: Bool,
        isFocused: Bool
    ) -> Bool {
        guard isWorkspaceVisible else { return false }
        // During pane/tab reparenting, Bonsplit can transiently report selected=false
        // for the currently focused panel. Keep focused content visible to avoid blank frames.
        return isSelectedInPane || isFocused
    }

    var body: some View {
        let appearance = PanelAppearance.fromConfig(config)
        let isSplit = workspace.bonsplitController.allPaneIds.count > 1 ||
            workspace.panels.count > 1
        let usesWorkspacePaneOverlay = TmuxOverlayExperimentSettings.target().usesWorkspacePaneOverlay
        let isWorkspaceManuallyUnread = notificationStore.hasManualUnread(forTabId: workspace.id)
        let workspaceManualUnreadPanelId = workspace.representativePanelIdForWorkspaceManualUnread()

        // Inactive workspaces are kept alive in a ZStack (for state preservation) but their
        // AppKit-backed views can still intercept drags. Disable drop acceptance for them.
        let _ = { workspace.bonsplitController.isInteractive = isWorkspaceInputActive }()

        // Wire up file drop handling so bonsplit's PaneDragContainerView can forward
        // Finder file drops to the correct terminal panel.
        let _ = {
            workspace.bonsplitController.onFileDrop = { [weak workspace] urls, paneId in
                guard let workspace else { return false }
                // Find the focused panel in this pane and drop the files into it.
                guard let tabId = workspace.bonsplitController.selectedTab(inPane: paneId)?.id,
                      let panelId = workspace.panelIdFromSurfaceId(tabId),
                      let panel = workspace.panels[panelId] as? TerminalPanel else { return false }
                return panel.hostedView.handleDroppedURLs(urls)
            }
        }()

        let bonsplitView = BonsplitView(controller: workspace.bonsplitController) { tab, paneId in
            // Content for each tab in bonsplit
            let _ = Self.debugPanelLookup(tab: tab, workspace: workspace)
            if let panel = workspace.panel(for: tab.id) {
                let isFocused = isWorkspaceInputActive && workspace.focusedPanelId == panel.id
                let isSelectedInPane = workspace.bonsplitController.selectedTab(inPane: paneId)?.id == tab.id
                let isVisibleInUI = Self.panelVisibleInUI(
                    isWorkspaceVisible: isWorkspaceVisible,
                    isSelectedInPane: isSelectedInPane,
                    isFocused: isFocused
                )
                let showsNotificationRing = Workspace.shouldShowUnreadIndicator(
                    hasUnreadNotification: notificationStore.hasVisibleNotificationIndicator(
                        forTabId: workspace.id,
                        surfaceId: panel.id
                    ),
                    hasPanelUnreadIndicator: workspace.manualUnreadPanelIds.contains(panel.id) ||
                        workspace.restoredUnreadPanelIds.contains(panel.id),
                    isWorkspaceManuallyUnread: isWorkspaceManuallyUnread,
                    isWorkspaceManualUnreadRepresentative: workspaceManualUnreadPanelId == panel.id
                )
                if let windowMirror = workspace.remoteTmuxWindowMirror(forPanelId: panel.id) {
                    // Multi-pane tmux window: render its pane layout as splits
                    // inside this single tab. Single-pane windows keep the
                    // standard PanelContentView path below.
                    RemoteTmuxWindowMirrorView(
                        mirror: windowMirror,
                        appearance: appearance,
                        isVisibleInUI: isVisibleInUI,
                        portalPriority: workspacePortalPriority,
                        onClosePane: { tmuxPaneId in
                            workspace.requestRemoteTmuxPaneClose(
                                windowMirror: windowMirror, tmuxPaneId: tmuxPaneId
                            )
                        }
                    )
                    .onTapGesture {
                        workspace.bonsplitController.focusPane(paneId)
                    }
                } else {
                    PanelContentView(
                        panel: panel,
                        workspaceId: workspace.id,
                        paneId: paneId,
                        isFocused: isFocused,
                        isSelectedInPane: isSelectedInPane,
                        isVisibleInUI: isVisibleInUI,
                        portalPriority: workspacePortalPriority,
                        isSplit: isSplit,
                        appearance: appearance, windowAppearance: windowAppearance, customSidebarTabManager: workspace.owningTabManager,
                        hasUnreadNotification: showsNotificationRing && !usesWorkspacePaneOverlay,
                        terminalAgentContext: Self.terminalAgentContext(panel: panel, workspace: workspace),
                        onFocus: {
                            // Keep bonsplit focus in sync with the AppKit first responder for the
                            // active workspace. This prevents divergence between the blue focused-tab
                            // indicator and where keyboard input/flash-focus actually lands.
                            guard isWorkspaceInputActive else { return }
                            guard workspace.panels[panel.id] != nil else { return }
                            workspace.focusPanel(panel.id, trigger: .terminalFirstResponder)
                        },
                        onRequestPanelFocus: {
                            guard isWorkspaceInputActive else { return }
                            guard workspace.panels[panel.id] != nil else { return }
                            AppDelegate.shared?.noteMainPanelKeyboardFocusIntent(
                                workspaceId: workspace.id,
                                panelId: panel.id,
                                in: NSApp.keyWindow ?? NSApp.mainWindow
                            )
                            workspace.focusPanel(panel.id)
                        },
                        onResumeAgentHibernation: {
                            guard isWorkspaceInputActive else { return }
                            guard workspace.panels[panel.id] != nil else { return }
                            workspace.resumeAgentHibernation(panelId: panel.id, focus: true)
                        },
                        onAutoResumeAgentHibernation: {
                            guard isWorkspaceInputActive else { return }
                            guard workspace.panels[panel.id] != nil else { return }
                            workspace.resumeAgentHibernation(panelId: panel.id, focus: false)
                        },
                        onTriggerFlash: { workspace.triggerDebugFlash(panelId: panel.id) }
                    )
                    .onTapGesture {
                        workspace.bonsplitController.focusPane(paneId)
                    }
                }
            } else {
                // Fallback for tabs without panels (shouldn't happen normally)
                EmptyPanelView(workspace: workspace, paneId: paneId)
            }
        } emptyPane: { paneId in
            // Empty pane content
            EmptyPanelView(workspace: workspace, paneId: paneId)
                .onTapGesture {
                    workspace.bonsplitController.focusPane(paneId)
                }
        }
        .internalOnlyTabDrag()
        // Split zoom swaps Bonsplit between the full split tree and a single pane view.
        // Recreate the Bonsplit subtree on zoom enter/exit so stale pre-zoom pane chrome
        // cannot remain stacked above portal-hosted browser content.
        .id(splitZoomRenderIdentity)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            updateAgentHibernationPresentationVisibility()
            syncBonsplitNotificationBadges()
            refreshGhosttyAppearanceConfig(reason: "onAppear")
        }
        .onChange(of: isWorkspaceVisible) { _, isVisible in
            updateAgentHibernationPresentationVisibility()
            guard isVisible else { return }
            flushDeferredThemeRefreshIfNeeded()
        }
        .onChange(of: isWorkspaceInputActive) { _, _ in
            updateAgentHibernationPresentationVisibility()
        }
        .onDisappear {
            workspace.setAgentHibernationAutoResumePresentationVisible(false)
        }
        .onChange(of: notificationStore.notifications) { _, _ in
            syncBonsplitNotificationBadges()
        }
        .onChange(of: workspace.manualUnreadPanelIds) { _, _ in
            syncBonsplitNotificationBadges()
        }
        .onChange(of: workspace.restoredUnreadPanelIds) { _, _ in
            syncBonsplitNotificationBadges()
        }
        .onChange(of: isWorkspaceManuallyUnread) { _, _ in
            syncBonsplitNotificationBadges()
        }
        .onChange(of: workspaceManualUnreadPanelId) { _, _ in
            syncBonsplitNotificationBadges()
        }
        .onReceive(NotificationCenter.default.publisher(for: .ghosttyConfigDidReload)) { _ in
            refreshGhosttyAppearanceConfig(reason: "ghosttyConfigDidReload")
        }
        .onChange(of: colorScheme) { oldValue, newValue in
            // Keep split overlay color/opacity in sync with light/dark theme transitions.
            refreshGhosttyAppearanceConfig(reason: "colorSchemeChanged:\(oldValue)->\(newValue)")
        }
        .onReceive(NotificationCenter.default.publisher(for: .ghosttyDefaultBackgroundDidChange)) { notification in
            let payloadHex = (notification.userInfo?[GhosttyNotificationKey.backgroundColor] as? NSColor)?.hexString() ?? "nil"
            let foregroundHex = (notification.userInfo?[GhosttyNotificationKey.foregroundColor] as? NSColor)?.hexString() ?? "nil"
            let eventId = (notification.userInfo?[GhosttyNotificationKey.backgroundEventId] as? NSNumber)?.uint64Value
            let source = (notification.userInfo?[GhosttyNotificationKey.backgroundSource] as? String) ?? "nil"
            logTheme(
                "theme notification workspace=\(workspace.id.uuidString) event=\(eventId.map(String.init) ?? "nil") source=\(source) payload=\(payloadHex) payloadFg=\(foregroundHex) appBg=\(GhosttyApp.shared.defaultBackgroundColor.hexString()) appFg=\(GhosttyApp.shared.defaultForegroundColor.hexString()) appOpacity=\(String(format: "%.3f", GhosttyApp.shared.defaultBackgroundOpacity))"
            )
            // Payload ordering can lag across rapid config/theme updates.
            // Resolve from GhosttyApp.shared.defaultBackgroundColor to keep tabs aligned
            // with Ghostty's current runtime theme.
            refreshGhosttyAppearanceConfig(
                reason: "ghosttyDefaultBackgroundDidChange",
                backgroundEventId: eventId,
                backgroundSource: source,
                notificationPayloadHex: payloadHex
            )
        }

        Group {
            if workspace.layoutMode == .canvas {
                WorkspaceCanvasHostView(
                    workspace: workspace,
                    isWorkspaceVisible: isWorkspaceVisible,
                    isWorkspaceInputActive: isWorkspaceInputActive,
                    portalPriority: workspacePortalPriority,
                    appearance: appearance, windowAppearance: windowAppearance
                )
            } else {
                bonsplitView
            }
        }
        .ignoresSafeArea(.container, edges: (isMinimalMode && !isFullScreen) ? .top : [])
    }

    private func syncBonsplitNotificationBadges() {
        let manualUnread = workspace.manualUnreadPanelIds
        let restoredUnread = workspace.restoredUnreadPanelIds
        let isWorkspaceManuallyUnread = notificationStore.hasManualUnread(forTabId: workspace.id)
        let workspaceManualUnreadPanelId = workspace.representativePanelIdForWorkspaceManualUnread()

        for paneId in workspace.bonsplitController.allPaneIds {
            for tab in workspace.bonsplitController.tabs(inPane: paneId) {
                let panelId = workspace.panelIdFromSurfaceId(tab.id)
                let expectedKind = panelId.flatMap { workspace.panelKind(panelId: $0) }
                let expectedPinned = panelId.map { workspace.isPanelPinned($0) } ?? false
                let shouldShow = panelId.map {
                    Workspace.shouldShowUnreadIndicator(
                        hasUnreadNotification: notificationStore.hasVisibleNotificationIndicator(
                            forTabId: workspace.id,
                            surfaceId: $0
                        ),
                        hasPanelUnreadIndicator: manualUnread.contains($0) || restoredUnread.contains($0),
                        isWorkspaceManuallyUnread: isWorkspaceManuallyUnread,
                        isWorkspaceManualUnreadRepresentative: workspaceManualUnreadPanelId == $0
                    )
                } ?? false
                let kindUpdate: String?? = expectedKind.map { .some($0) }

                if tab.showsNotificationBadge != shouldShow ||
                    tab.isPinned != expectedPinned ||
                    (expectedKind != nil && tab.kind != expectedKind) {
                    workspace.bonsplitController.updateTab(
                        tab.id,
                        kind: kindUpdate,
                        showsNotificationBadge: shouldShow,
                        isPinned: expectedPinned
                    )
                }
            }
        }
    }

    private var splitZoomRenderIdentity: String {
        workspace.bonsplitController.zoomedPaneId.map { "zoom:\($0.id.uuidString)" } ?? "unzoomed"
    }

    private static let tmuxPaneOverlayGeometry = TmuxPaneOverlayGeometry(
        topChromeHeight: MinimalModeChromeMetrics.titlebarHeight
    )

    private static func tmuxWorkspacePaneRects(
        workspace: Workspace,
        notificationStore: TerminalNotificationStore,
        layoutSnapshot: LayoutSnapshot?,
        includeContainerOffset: Bool
    ) -> [CGRect] {
        guard let layoutSnapshot else { return [] }
        let geometry = tmuxPaneOverlayGeometry
        let isWorkspaceManuallyUnread = notificationStore.hasManualUnread(forTabId: workspace.id)
        let workspaceManualUnreadPanelId = workspace.representativePanelIdForWorkspaceManualUnread()

        return layoutSnapshot.panes.compactMap { pane in
            guard let selectedTabId = pane.selectedTabId,
                  let tabUUID = UUID(uuidString: selectedTabId),
                  let panelId = workspace.panelIdFromSurfaceId(TabID(uuid: tabUUID)) else {
                return nil
            }

            let shouldShowUnread = Workspace.shouldShowUnreadIndicator(
                hasUnreadNotification: notificationStore.hasVisibleNotificationIndicator(
                    forTabId: workspace.id,
                    surfaceId: panelId
                ),
                hasPanelUnreadIndicator: workspace.manualUnreadPanelIds.contains(panelId) ||
                    workspace.restoredUnreadPanelIds.contains(panelId),
                isWorkspaceManuallyUnread: isWorkspaceManuallyUnread,
                isWorkspaceManualUnreadRepresentative: workspaceManualUnreadPanelId == panelId
            )
            guard shouldShowUnread else { return nil }

            let paneRect = pane.frame.cgRect
            let rect: CGRect
            if includeContainerOffset {
                rect = paneRect.offsetBy(
                    dx: 0,
                    dy: -CGFloat(layoutSnapshot.containerFrame.y)
                )
            } else {
                rect = paneRect.offsetBy(
                    dx: -CGFloat(layoutSnapshot.containerFrame.x),
                    dy: -CGFloat(layoutSnapshot.containerFrame.y)
                )
            }
            return geometry.contentRect(rect)
        }
    }

    static func tmuxWorkspacePaneOverlayRect(
        layoutSnapshot: LayoutSnapshot?,
        paneId: PaneID?
    ) -> CGRect? {
        tmuxPaneOverlayGeometry.overlayRect(
            layoutSnapshot: layoutSnapshot,
            paneId: paneId
        )
    }

    static func tmuxWorkspacePaneWindowOverlayRect(
        layoutSnapshot: LayoutSnapshot?,
        paneId: PaneID?
    ) -> CGRect? {
        tmuxPaneOverlayGeometry.windowOverlayRect(
            layoutSnapshot: layoutSnapshot,
            paneId: paneId
        )
    }

    static func effectiveTmuxLayoutSnapshot(
        cachedSnapshot: LayoutSnapshot?,
        liveSnapshot: LayoutSnapshot?
    ) -> LayoutSnapshot? {
        tmuxPaneOverlayGeometry.effectiveSnapshot(
            cachedSnapshot: cachedSnapshot,
            liveSnapshot: liveSnapshot
        )
    }

    static func tmuxWorkspacePaneUnreadRects(
        workspace: Workspace,
        notificationStore: TerminalNotificationStore,
        layoutSnapshot: LayoutSnapshot?
    ) -> [CGRect] {
        tmuxWorkspacePaneRects(
            workspace: workspace,
            notificationStore: notificationStore,
            layoutSnapshot: layoutSnapshot,
            includeContainerOffset: false
        )
    }

    static func tmuxWorkspacePaneWindowUnreadRects(
        workspace: Workspace,
        notificationStore: TerminalNotificationStore,
        layoutSnapshot: LayoutSnapshot?
    ) -> [CGRect] {
        tmuxWorkspacePaneRects(
            workspace: workspace,
            notificationStore: notificationStore,
            layoutSnapshot: layoutSnapshot,
            includeContainerOffset: true
        )
    }

    private func flushDeferredThemeRefreshIfNeeded() {
        guard isWorkspaceVisible,
              let deferredRefresh = deferredThemeRefresh else { return }
        deferredThemeRefresh = nil
        refreshGhosttyAppearanceConfig(
            reason: deferredRefresh.reason,
            backgroundOverride: deferredRefresh.backgroundOverride,
            backgroundEventId: deferredRefresh.backgroundEventId,
            backgroundSource: deferredRefresh.backgroundSource,
            notificationPayloadHex: deferredRefresh.notificationPayloadHex,
            forceInitialApply: deferredRefresh.forceInitialApply
        )
    }

    private func updateAgentHibernationPresentationVisibility() {
        workspace.setAgentHibernationAutoResumePresentationVisible(isWorkspaceVisible && isWorkspaceInputActive)
    }

    private func refreshGhosttyAppearanceConfig(
        reason: String,
        backgroundOverride: NSColor? = nil,
        backgroundEventId: UInt64? = nil,
        backgroundSource: String? = nil,
        notificationPayloadHex: String? = nil,
        forceInitialApply: Bool = false
    ) {
        guard isWorkspaceVisible else {
            let existing = deferredThemeRefresh
            deferredThemeRefresh = DeferredThemeRefresh(
                reason: reason,
                backgroundOverride: backgroundOverride,
                backgroundEventId: backgroundEventId,
                backgroundSource: backgroundSource,
                notificationPayloadHex: notificationPayloadHex,
                forceInitialApply: forceInitialApply
                    || reason == "onAppear"
                    || existing?.forceInitialApply == true
            )
            return
        }
        deferredThemeRefresh = nil

        let previousSignature = Self.ghosttyAppearanceSignature(
            config,
            usesHostLayerBackground: lastAppliedUsesHostLayerBackground
        )
        let previousBackgroundHex = config.backgroundColor.hexString()
        let next = Self.resolveGhosttyAppearanceConfig(
            reason: reason,
            backgroundOverride: backgroundOverride
        )
        let nextUsesHostLayerBackground = GhosttyApp.shared.usesHostLayerBackground
        let nextSignature = Self.ghosttyAppearanceSignature(
            next,
            usesHostLayerBackground: nextUsesHostLayerBackground
        )
        let eventLabel = backgroundEventId.map(String.init) ?? "nil"
        let sourceLabel = backgroundSource ?? "nil"
        let payloadLabel = notificationPayloadHex ?? "nil"
        let configChanged = previousSignature != nextSignature
        let backgroundChanged = previousBackgroundHex != next.backgroundColor.hexString()
        let opacityChanged = abs(config.backgroundOpacity - next.backgroundOpacity) > 0.0001
        let blurChanged = config.backgroundBlur != next.backgroundBlur
        let shouldForceInitialApply = forceInitialApply || reason == "onAppear"
        let shouldRequestTitlebarRefresh = backgroundChanged || opacityChanged || blurChanged || shouldForceInitialApply
        let shouldApplyChrome = configChanged || shouldForceInitialApply
        let shouldRefreshWindowBackground = backgroundChanged || opacityChanged || blurChanged || shouldForceInitialApply
        if !shouldApplyChrome && !shouldRefreshWindowBackground && !shouldRequestTitlebarRefresh {
            logTheme(
                "theme refresh skip workspace=\(workspace.id.uuidString) reason=\(reason) event=\(eventLabel) source=\(sourceLabel) payload=\(payloadLabel)"
            )
            return
        }
        logTheme(
            "theme refresh begin workspace=\(workspace.id.uuidString) reason=\(reason) event=\(eventLabel) source=\(sourceLabel) payload=\(payloadLabel) previousBg=\(previousBackgroundHex) nextBg=\(next.backgroundColor.hexString()) overrideBg=\(backgroundOverride?.hexString() ?? "nil")"
        )
        withTransaction(Transaction(animation: nil)) {
            if configChanged {
                config = next
            }
            if shouldApplyChrome {
                lastAppliedUsesHostLayerBackground = nextUsesHostLayerBackground
            }
            if shouldRequestTitlebarRefresh {
                onThemeRefreshRequest?(
                    reason,
                    backgroundEventId,
                    backgroundSource,
                    notificationPayloadHex
                )
            }
        }
        if !shouldRequestTitlebarRefresh {
            logTheme(
                "theme refresh titlebar-skip workspace=\(workspace.id.uuidString) reason=\(reason) event=\(eventLabel) previousBg=\(previousBackgroundHex) nextBg=\(next.backgroundColor.hexString())"
            )
        }
        logTheme(
            "theme refresh config-applied workspace=\(workspace.id.uuidString) reason=\(reason) event=\(eventLabel) configBg=\(config.backgroundColor.hexString())"
        )
        let chromeReason =
            "refreshGhosttyAppearanceConfig:reason=\(reason):event=\(eventLabel):source=\(sourceLabel):payload=\(payloadLabel)"
        if shouldApplyChrome {
            workspace.applyGhosttyChrome(from: next, reason: chromeReason)
        }
        if shouldRefreshWindowBackground {
            if let terminalPanel = workspace.focusedTerminalPanel {
                terminalPanel.applyWindowBackgroundIfActive()
                logTheme(
                    "theme refresh terminal-applied workspace=\(workspace.id.uuidString) reason=\(reason) event=\(eventLabel) panel=\(workspace.focusedPanelId?.uuidString ?? "nil")"
                )
            } else {
                logTheme(
                    "theme refresh terminal-skipped workspace=\(workspace.id.uuidString) reason=\(reason) event=\(eventLabel) focusedPanel=\(workspace.focusedPanelId?.uuidString ?? "nil")"
                )
            }
        }
        logTheme(
            "theme refresh end workspace=\(workspace.id.uuidString) reason=\(reason) event=\(eventLabel) chromeBg=\(workspace.bonsplitController.configuration.appearance.chromeColors.backgroundHex ?? "nil")"
        )
    }

    private func logTheme(_ message: String) {
        guard GhosttyApp.shared.backgroundLogEnabled else { return }
        GhosttyApp.shared.logBackground(message)
    }
}

extension WorkspaceContentView {
    static func terminalAgentContext(panel: any Panel, workspace: Workspace) -> String {
        var parts: [String] = []
        if let terminalPanel = panel as? TerminalPanel {
            if let initialCommand = terminalPanel.surface.initialCommand {
                parts.append("initialCommand:\(initialCommand)")
            }
            if let tmuxStartCommand = terminalPanel.surface.tmuxStartCommand {
                parts.append("tmuxStartCommand:\(tmuxStartCommand)")
            }
        }
        if let restoredAgent = workspace.restoredAgentSnapshotsByPanelId[panel.id] {
            parts.append("restoredAgent:\(restoredAgent.kind.rawValue)")
        }
        if let agentPIDKeys = workspace.agentPIDKeysByPanelId[panel.id], !agentPIDKeys.isEmpty {
            for key in agentPIDKeys.sorted() {
                parts.append("agentPIDKey:\(key)")
            }
        }
        return parts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    #if DEBUG
    static func debugPanelLookup(tab: Bonsplit.Tab, workspace: Workspace) {
        let found = workspace.panel(for: tab.id) != nil
        if !found {
            let ts = ISO8601DateFormatter().string(from: Date())
            let line = "[\(ts)] PANEL NOT FOUND for tabId=\(tab.id) ws=\(workspace.id) panelCount=\(workspace.panels.count)\n"
            let logPath = "/tmp/cmux-panel-debug.log"
            if let handle = FileHandle(forWritingAtPath: logPath) {
                defer { try? handle.close() }
                guard (try? handle.seekToEnd()) != nil else { return }
                try? handle.write(contentsOf: Data(line.utf8))
            } else {
                FileManager.default.createFile(atPath: logPath, contents: line.data(using: .utf8))
            }
        }
    }
    #else
    static func debugPanelLookup(tab: Bonsplit.Tab, workspace: Workspace) {
        _ = tab
        _ = workspace
    }
    #endif
}

/// View shown for empty panes
struct EmptyPanelView: View {
    @ObservedObject var workspace: Workspace
    let paneId: PaneID
    @ObservedObject private var keyboardShortcutSettingsObserver = KeyboardShortcutSettingsObserver.shared

    private struct ShortcutHint: View {
        let text: String

        var body: some View {
            Text(text)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.white.opacity(0.18), in: Capsule())
        }
    }

    private func focusPane() {
        workspace.bonsplitController.focusPane(paneId)
    }

    private func createTerminal() {
        #if DEBUG
        cmuxDebugLog("emptyPane.newTerminal pane=\(paneId.id.uuidString.prefix(5))")
        #endif
        focusPane()
        _ = workspace.newTerminalSurface(inPane: paneId, inheritWorkingDirectoryFallback: true)
    }

    private func createBrowser() {
        #if DEBUG
        cmuxDebugLog("emptyPane.newBrowser pane=\(paneId.id.uuidString.prefix(5))")
        #endif
        focusPane()
        _ = workspace.newBrowserSurface(inPane: paneId)
    }

    private var newSurfaceShortcut: StoredShortcut {
        let _ = keyboardShortcutSettingsObserver.revision
        return KeyboardShortcutSettings.shortcut(for: .newSurface)
    }

    private var openBrowserShortcut: StoredShortcut {
        let _ = keyboardShortcutSettingsObserver.revision
        return KeyboardShortcutSettings.shortcut(for: .openBrowser)
    }

    @ViewBuilder
    private func emptyPaneActionButton(
        title: String,
        systemImage: String,
        shortcut: StoredShortcut,
        action: @escaping () -> Void
    ) -> some View {
        if let key = shortcut.keyEquivalent {
            Button(action: action) {
                HStack(spacing: 10) {
                    Label(title, systemImage: systemImage)
                    ShortcutHint(text: shortcut.displayString)
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(key, modifiers: shortcut.eventModifiers)
        } else {
            Button(action: action) {
                HStack(spacing: 10) {
                    Label(title, systemImage: systemImage)
                    ShortcutHint(text: shortcut.displayString)
                }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "terminal.fill")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)

            Text("Empty Panel")
                .font(.headline)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                emptyPaneActionButton(
                    title: "Terminal",
                    systemImage: "terminal.fill",
                    shortcut: newSurfaceShortcut,
                    action: createTerminal
                )

                emptyPaneActionButton(
                    title: "Browser",
                    systemImage: "globe",
                    shortcut: openBrowserShortcut,
                    action: createBrowser
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: GhosttyBackgroundTheme.currentColor()))
#if DEBUG
        .onAppear {
            DebugUIEventCounters.emptyPanelAppearCount += 1
        }
#endif
    }
}

#if DEBUG
@MainActor
enum DebugUIEventCounters {
    static var emptyPanelAppearCount: Int = 0

    static func resetEmptyPanelAppearCount() {
        emptyPanelAppearCount = 0
    }
}
#endif
