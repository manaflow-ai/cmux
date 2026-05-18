import SwiftUI
import Foundation
import AppKit
import Bonsplit
import UniformTypeIdentifiers

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

struct TmuxPaneLayoutPane: Codable, Equatable, Sendable {
    let paneId: String
    let left: Int
    let top: Int
    let width: Int
    let height: Int
    let isActive: Bool
}

struct TmuxPaneLayoutReport: Codable, Equatable, Sendable {
    let panes: [TmuxPaneLayoutPane]

    var activePane: TmuxPaneLayoutPane? {
        panes.first(where: \.isActive) ?? panes.first
    }
}

func tmuxActivePaneOverlayRect(
    surfaceFrame: CGRect,
    cellSize: CGSize,
    pane: TmuxPaneLayoutPane
) -> CGRect? {
    guard cellSize.width > 0,
          cellSize.height > 0,
          pane.width > 0,
          pane.height > 0 else {
        return nil
    }

    return CGRect(
        x: surfaceFrame.origin.x + (CGFloat(pane.left) * cellSize.width),
        y: surfaceFrame.origin.y + (CGFloat(pane.top) * cellSize.height),
        width: CGFloat(pane.width) * cellSize.width,
        height: CGFloat(pane.height) * cellSize.height
    )
}

private extension PixelRect {
    var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
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

    private var lastWorkspaceId: UUID?
    private var lastFlashToken: UInt64?

    func apply(
        _ state: TmuxWorkspacePaneOverlayRenderState,
        now: () -> Date = Date.init
    ) {
        unreadRects = state.unreadRects
        flashRect = state.flashRect
        flashReason = state.flashReason

        let didChangeWorkspace = lastWorkspaceId != state.workspaceId
        if didChangeWorkspace {
            lastWorkspaceId = state.workspaceId
            lastFlashToken = state.flashToken
            flashStartedAt = nil
            return
        }

        if let lastFlashToken,
           state.flashToken != lastFlashToken,
           state.flashRect != nil {
            flashStartedAt = now()
        }
        self.lastFlashToken = state.flashToken
    }

    func clear() {
        unreadRects = []
        flashRect = nil
        flashStartedAt = nil
        flashReason = nil
        lastWorkspaceId = nil
        lastFlashToken = nil
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

    private var isMinimalMode: Bool {
        WorkspacePresentationModeSettings.mode(for: workspacePresentationMode) == .minimal
    }

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

        // Inactive workspaces are kept alive in a ZStack (for state preservation) but their
        // AppKit-backed views can still intercept drags. Disable drop acceptance for them.
        let _ = { workspace.bonsplitController.isInteractive = isWorkspaceInputActive }()
        let _ = {
            for controller in workspace.dockLayout.allControllers {
                controller.isInteractive = isWorkspaceInputActive
            }
        }()

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
                    isManuallyUnread: workspace.manualUnreadPanelIds.contains(panel.id)
                )
                PanelContentView(
                    panel: panel,
                    workspaceId: workspace.id,
                    paneId: paneId,
                    isFocused: isFocused,
                    isSelectedInPane: isSelectedInPane,
                    isVisibleInUI: isVisibleInUI,
                    portalPriority: workspacePortalPriority,
                    isSplit: isSplit,
                    appearance: appearance,
                    hasUnreadNotification: showsNotificationRing && !usesWorkspacePaneOverlay,
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
                    onTriggerFlash: { workspace.triggerDebugFlash(panelId: panel.id) }
                )
                .onTapGesture {
                    workspace.bonsplitController.focusPane(paneId)
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
            syncBonsplitNotificationBadges()
            refreshGhosttyAppearanceConfig(reason: "onAppear")
        }
        .onChange(of: isWorkspaceVisible) { _, isVisible in
            guard isVisible else { return }
            flushDeferredThemeRefreshIfNeeded()
        }
        .onChange(of: notificationStore.notifications) { _, _ in
            syncBonsplitNotificationBadges()
        }
        .onChange(of: workspace.manualUnreadPanelIds) { _, _ in
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

        WorkspaceMultiDockLayoutView(
            workspace: workspace,
            layout: workspace.dockLayout,
            isWorkspaceVisible: isWorkspaceVisible,
            isWorkspaceInputActive: isWorkspaceInputActive,
            isSplit: isSplit,
            appearance: appearance,
            usesWorkspacePaneOverlay: usesWorkspacePaneOverlay,
            portalPriority: workspacePortalPriority + 1
        ) {
            bonsplitView
        }
            .ignoresSafeArea(.container, edges: (isMinimalMode && !isFullScreen) ? .top : [])
    }

    private func syncBonsplitNotificationBadges() {
        let manualUnread = workspace.manualUnreadPanelIds

        for controller in workspace.allBonsplitControllers {
            for paneId in controller.allPaneIds {
                for tab in controller.tabs(inPane: paneId) {
                let panelId = workspace.panelIdFromSurfaceId(tab.id)
                let expectedKind = panelId.flatMap { workspace.panelKind(panelId: $0) }
                let expectedPinned = panelId.map { workspace.isPanelPinned($0) } ?? false
                let shouldShow = panelId.map {
                    notificationStore.hasVisibleNotificationIndicator(forTabId: workspace.id, surfaceId: $0) ||
                        manualUnread.contains($0)
                } ?? false
                let kindUpdate: String?? = expectedKind.map { .some($0) }

                if tab.showsNotificationBadge != shouldShow ||
                    tab.isPinned != expectedPinned ||
                    (expectedKind != nil && tab.kind != expectedKind) {
                    controller.updateTab(
                        tab.id,
                        kind: kindUpdate,
                        showsNotificationBadge: shouldShow,
                        isPinned: expectedPinned
                    )
                }
            }
        }
        }
    }

    private var splitZoomRenderIdentity: String {
        workspace.bonsplitController.zoomedPaneId.map { "zoom:\($0.id.uuidString)" } ?? "unzoomed"
    }

    private static let tmuxWorkspacePaneTopChromeHeight: CGFloat = MinimalModeChromeMetrics.titlebarHeight

    private enum TmuxWorkspacePaneOverlayTrimMode {
        case workspaceLocal
        case windowContent
    }

    private static func tmuxWorkspacePaneContentRect(
        _ rect: CGRect,
        trimMode: TmuxWorkspacePaneOverlayTrimMode
    ) -> CGRect {
        let topInset = min(tmuxWorkspacePaneTopChromeHeight, max(0, rect.height - 1))
        switch trimMode {
        case .workspaceLocal, .windowContent:
            return CGRect(
                x: rect.origin.x,
                y: rect.origin.y + topInset,
                width: rect.width,
                height: max(0, rect.height - topInset)
            )
        }
    }

    private static func tmuxWorkspacePaneRect(
        layoutSnapshot: LayoutSnapshot?,
        paneId: PaneID?,
        includeContainerOffset: Bool,
        trimMode: TmuxWorkspacePaneOverlayTrimMode
    ) -> CGRect? {
        guard let layoutSnapshot,
              let paneId,
              let paneRect = layoutSnapshot.panes
                .first(where: { $0.paneId == paneId.id.uuidString })?
                .frame
                .cgRect else {
            return nil
        }

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
        return tmuxWorkspacePaneContentRect(rect, trimMode: trimMode)
    }

    private static func tmuxWorkspacePaneRects(
        workspace: Workspace,
        notificationStore: TerminalNotificationStore,
        layoutSnapshot: LayoutSnapshot?,
        includeContainerOffset: Bool,
        trimMode: TmuxWorkspacePaneOverlayTrimMode
    ) -> [CGRect] {
        guard let layoutSnapshot else { return [] }

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
                isManuallyUnread: workspace.manualUnreadPanelIds.contains(panelId)
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
            return tmuxWorkspacePaneContentRect(rect, trimMode: trimMode)
        }
    }

    static func tmuxWorkspacePaneOverlayRect(
        layoutSnapshot: LayoutSnapshot?,
        paneId: PaneID?
    ) -> CGRect? {
        tmuxWorkspacePaneRect(
            layoutSnapshot: layoutSnapshot,
            paneId: paneId,
            includeContainerOffset: false,
            trimMode: .workspaceLocal
        )
    }

    static func tmuxWorkspacePaneWindowOverlayRect(
        layoutSnapshot: LayoutSnapshot?,
        paneId: PaneID?
    ) -> CGRect? {
        tmuxWorkspacePaneRect(
            layoutSnapshot: layoutSnapshot,
            paneId: paneId,
            includeContainerOffset: true,
            trimMode: .windowContent
        )
    }

    static func effectiveTmuxLayoutSnapshot(
        cachedSnapshot: LayoutSnapshot?,
        liveSnapshot: LayoutSnapshot?
    ) -> LayoutSnapshot? {
        if let liveSnapshot,
           tmuxLayoutSnapshotHasRenderableGeometry(liveSnapshot) {
            return liveSnapshot
        }
        if let cachedSnapshot,
           tmuxLayoutSnapshotHasRenderableGeometry(cachedSnapshot) {
            return cachedSnapshot
        }
        return cachedSnapshot ?? liveSnapshot
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
            includeContainerOffset: false,
            trimMode: .workspaceLocal
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
            includeContainerOffset: true,
            trimMode: .windowContent
        )
    }

    private static func tmuxLayoutSnapshotHasRenderableGeometry(_ snapshot: LayoutSnapshot) -> Bool {
        snapshot.containerFrame.width > 1 &&
            snapshot.containerFrame.height > 1 &&
            snapshot.panes.contains { pane in
                pane.frame.width > 1 && pane.frame.height > 1
            }
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

private struct WorkspaceMultiDockLayoutView<MainContent: View>: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var layout: WorkspaceDockLayout
    let isWorkspaceVisible: Bool
    let isWorkspaceInputActive: Bool
    let isSplit: Bool
    let appearance: PanelAppearance
    let usesWorkspacePaneOverlay: Bool
    let portalPriority: Int
    @ViewBuilder let mainContent: () -> MainContent
    @State private var targetedRevealEdges: Set<WorkspaceDockEdge> = []

    private let sideDockWidth: CGFloat = 240
    private let bottomDockHeight: CGFloat = 220
    private let tabTransferType = UTType(exportedAs: "com.splittabbar.tabtransfer", conformingTo: .data)

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    if layout.isEdgeOpen(.left) {
                        dockStrip(edge: .left, docks: layout.left)
                    }
                    mainContent()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if layout.isEdgeOpen(.right) {
                        dockStrip(edge: .right, docks: layout.right)
                    }
                }
                if layout.isEdgeOpen(.bottom) {
                    Divider()
                    bottomDockStrip
                }
            }
            dockRevealZone(edge: .left)
            dockRevealZone(edge: .right)
            dockRevealZone(edge: .bottom)
        }
        .background(Color(nsColor: appearance.backgroundColor.withAlphaComponent(1)))
    }

    private func dockStrip(edge: WorkspaceDockEdge, docks: [WorkspaceDock]) -> some View {
        HStack(spacing: 0) {
            ForEach(docks) { dock in
                if edge == .right {
                    Divider()
                }
                WorkspaceDockPaneView(
                    workspace: workspace,
                    layout: layout,
                    dock: dock,
                    isWorkspaceVisible: isWorkspaceVisible,
                    isWorkspaceInputActive: isWorkspaceInputActive,
                    isSplit: isSplit,
                    appearance: appearance,
                    usesWorkspacePaneOverlay: usesWorkspacePaneOverlay,
                    portalPriority: portalPriority
                )
                .frame(width: dock.preferredSize ?? sideDockWidth)
                if edge == .left {
                    Divider()
                }
            }
        }
        .contextMenu {
            Button(addDockTitle(edge: edge)) {
                layout.addDock(edge: edge)
            }
        }
        .background(Color(nsColor: appearance.backgroundColor.withAlphaComponent(1)))
    }

    private var bottomDockStrip: some View {
        HStack(spacing: 0) {
            ForEach(layout.bottom) { dock in
                WorkspaceDockPaneView(
                    workspace: workspace,
                    layout: layout,
                    dock: dock,
                    isWorkspaceVisible: isWorkspaceVisible,
                    isWorkspaceInputActive: isWorkspaceInputActive,
                    isSplit: isSplit,
                    appearance: appearance,
                    usesWorkspacePaneOverlay: usesWorkspacePaneOverlay,
                    portalPriority: portalPriority
                )
                .frame(maxWidth: .infinity)
                Divider()
            }
        }
        .frame(height: bottomDockHeightForOpenDocks)
        .contextMenu {
            Button(addDockTitle(edge: .bottom)) {
                layout.addDock(edge: .bottom)
            }
        }
        .background(Color(nsColor: appearance.backgroundColor.withAlphaComponent(1)))
    }

    private var bottomDockHeightForOpenDocks: CGFloat {
        let configured = layout.bottom.compactMap(\.preferredSize).max() ?? bottomDockHeight
        return max(120, configured)
    }

    @ViewBuilder
    private func dockRevealZone(edge: WorkspaceDockEdge) -> some View {
        if !layout.isEdgeOpen(edge) {
            switch edge {
            case .left:
                HStack(spacing: 0) {
                    dockRevealHitTarget(edge: edge)
                        .frame(width: 10)
                        .frame(maxHeight: .infinity)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .right:
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    dockRevealHitTarget(edge: edge)
                        .frame(width: 10)
                        .frame(maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .bottom:
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    dockRevealHitTarget(edge: edge)
                        .frame(height: 10)
                        .frame(maxWidth: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func dockRevealHitTarget(edge: WorkspaceDockEdge) -> some View {
        Rectangle()
            .fill(Color.clear)
            .contentShape(Rectangle())
            .onDrop(of: [tabTransferType], isTargeted: revealBinding(edge: edge)) { _ in
                layout.openEdge(edge)
                return false
            }
    }

    private func revealBinding(edge: WorkspaceDockEdge) -> Binding<Bool> {
        Binding(
            get: { targetedRevealEdges.contains(edge) },
            set: { isTargeted in
                if isTargeted {
                    targetedRevealEdges.insert(edge)
                    layout.openEdge(edge)
                } else {
                    targetedRevealEdges.remove(edge)
                }
            }
        )
    }

    private func addDockTitle(edge: WorkspaceDockEdge) -> String {
        switch edge {
        case .left:
            return String(localized: "workspaceDock.add.left", defaultValue: "Add Left Dock")
        case .right:
            return String(localized: "workspaceDock.add.right", defaultValue: "Add Right Dock")
        case .bottom:
            return String(localized: "workspaceDock.add.bottom", defaultValue: "Add Bottom Dock")
        }
    }
}

struct WorkspaceDockToggleCluster: View {
    @ObservedObject var layout: WorkspaceDockLayout

    var body: some View {
        HStack(spacing: 0) {
            ForEach(WorkspaceDockEdge.controlOrder) { edge in
                Button {
                    layout.toggleEdge(edge)
                } label: {
                    WorkspaceDockToggleIcon(edge: edge, isOpen: layout.isEdgeOpen(edge))
                }
                .buttonStyle(.plain)
                .frame(width: 18, height: 16)
                .contentShape(Rectangle())
                .help(WorkspaceDockToggleText.helpTitle(edge: edge))
                .contextMenu {
                    Button(layout.isEdgeOpen(edge) ? WorkspaceDockToggleText.closeTitle(edge: edge) : WorkspaceDockToggleText.openTitle(edge: edge)) {
                        layout.toggleEdge(edge)
                    }

                    Menu(String(localized: "workspaceDock.count.menu", defaultValue: "Dock Count")) {
                        ForEach(layout.dockCountChoices(for: edge), id: \.self) { count in
                            Button(WorkspaceDockToggleText.dockCountTitle(count: count)) {
                                layout.setDockCount(edge: edge, count: count)
                            }
                            .disabled(!layout.canSetDockCount(edge: edge, count: count))
                        }
                    }

                    if layout.hasEmptyDocks(edge: edge) {
                        Divider()
                        Button(WorkspaceDockToggleText.removeEmptyDocksTitle(edge: edge), role: .destructive) {
                            layout.removeEmptyDocks(edge: edge)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 2)
        .frame(width: 58, height: 18)
        .background {
            Color.clear
            MinimalModeTitlebarControlHitRegionView()
        }
    }
}

struct WorkspaceDockTitlebarStateBinder: NSViewRepresentable {
    @ObservedObject var layout: WorkspaceDockLayout

    func makeNSView(context: Context) -> BinderView {
        BinderView(layout: layout)
    }

    func updateNSView(_ nsView: BinderView, context: Context) {
        nsView.layout = layout
        nsView.bindToWindow()
    }

    @MainActor
    final class BinderView: NSView {
        var layout: WorkspaceDockLayout {
            didSet {
                bindToWindow()
            }
        }
        private weak var boundWindow: CmuxMainWindow?

        init(layout: WorkspaceDockLayout) {
            self.layout = layout
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            bindToWindow()
        }

        func bindToWindow() {
            if boundWindow !== window as? CmuxMainWindow {
                if boundWindow?.workspaceDockTitlebarLayout === layout {
                    boundWindow?.workspaceDockTitlebarLayout = nil
                }
                boundWindow = window as? CmuxMainWindow
            }
            boundWindow?.workspaceDockTitlebarLayout = layout
        }
    }
}

private enum WorkspaceDockToggleText {
    static func helpTitle(edge: WorkspaceDockEdge) -> String {
        switch edge {
        case .left:
            return String(localized: "workspaceDock.toggle.left.help", defaultValue: "Toggle Left Dock")
        case .right:
            return String(localized: "workspaceDock.toggle.right.help", defaultValue: "Toggle Right Dock")
        case .bottom:
            return String(localized: "workspaceDock.toggle.bottom.help", defaultValue: "Toggle Bottom Dock")
        }
    }

    static func openTitle(edge: WorkspaceDockEdge) -> String {
        switch edge {
        case .left:
            return String(localized: "workspaceDock.open.left", defaultValue: "Open Left Dock")
        case .right:
            return String(localized: "workspaceDock.open.right", defaultValue: "Open Right Dock")
        case .bottom:
            return String(localized: "workspaceDock.open.bottom", defaultValue: "Open Bottom Dock")
        }
    }

    static func closeTitle(edge: WorkspaceDockEdge) -> String {
        switch edge {
        case .left:
            return String(localized: "workspaceDock.close.left", defaultValue: "Close Left Dock")
        case .right:
            return String(localized: "workspaceDock.close.right", defaultValue: "Close Right Dock")
        case .bottom:
            return String(localized: "workspaceDock.close.bottom", defaultValue: "Close Bottom Dock")
        }
    }

    static func dockCountTitle(count: Int) -> String {
        String(count)
    }

    static func removeEmptyDocksTitle(edge: WorkspaceDockEdge) -> String {
        switch edge {
        case .left:
            return String(localized: "workspaceDock.removeEmpty.left", defaultValue: "Remove Empty Left Docks")
        case .right:
            return String(localized: "workspaceDock.removeEmpty.right", defaultValue: "Remove Empty Right Docks")
        case .bottom:
            return String(localized: "workspaceDock.removeEmpty.bottom", defaultValue: "Remove Empty Bottom Docks")
        }
    }
}

private struct WorkspaceDockToggleIcon: View {
    let edge: WorkspaceDockEdge
    let isOpen: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                .stroke(iconColor, lineWidth: 1)
                .frame(width: 12, height: 9)
            RoundedRectangle(cornerRadius: 1.4, style: .continuous)
                .fill(iconColor.opacity(isOpen ? 0.95 : 0.45))
                .frame(width: stripeSize.width, height: stripeSize.height)
                .offset(stripeOffset)
        }
        .frame(width: 16, height: 16)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(isOpen ? Color.primary.opacity(0.055) : Color.clear)
        )
    }

    private var iconColor: Color {
        Color.primary.opacity(isOpen ? 0.58 : 0.30)
    }

    private var stripeSize: CGSize {
        switch edge {
        case .left, .right:
            return CGSize(width: 3.2, height: 7.4)
        case .bottom:
            return CGSize(width: 10, height: 3.2)
        }
    }

    private var stripeOffset: CGSize {
        switch edge {
        case .left:
            return CGSize(width: -3.8, height: 0)
        case .right:
            return CGSize(width: 3.8, height: 0)
        case .bottom:
            return CGSize(width: 0, height: 3.0)
        }
    }

}

private struct WorkspaceDockPaneView: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var layout: WorkspaceDockLayout
    @ObservedObject var dock: WorkspaceDock
    let isWorkspaceVisible: Bool
    let isWorkspaceInputActive: Bool
    let isSplit: Bool
    let appearance: PanelAppearance
    let usesWorkspacePaneOverlay: Bool
    let portalPriority: Int
    @EnvironmentObject var notificationStore: TerminalNotificationStore

    var body: some View {
        dockBonsplitView
            .background(Color(nsColor: appearance.backgroundColor.withAlphaComponent(1)))
            .contextMenu {
                Button(addDockTitle(edge: dock.edge)) {
                    layout.addDock(edge: dock.edge)
                }
                if layout.canRemove(dock) {
                    Divider()
                    Button(removeDockTitle, role: .destructive) {
                        layout.removeDock(dock)
                    }
                }
            }
    }

    private var dockBonsplitView: some View {
        BonsplitView(controller: dock.controller) { tab, paneId in
            if let panel = workspace.panel(for: tab.id) {
                let isFocused = isWorkspaceInputActive && workspace.focusedPanelId == panel.id
                let isSelectedInPane = dock.controller.selectedTab(inPane: paneId)?.id == tab.id
                let isVisibleInUI = WorkspaceContentView.panelVisibleInUI(
                    isWorkspaceVisible: isWorkspaceVisible,
                    isSelectedInPane: isSelectedInPane,
                    isFocused: isFocused
                )
                let showsNotificationRing = Workspace.shouldShowUnreadIndicator(
                    hasUnreadNotification: notificationStore.hasVisibleNotificationIndicator(
                        forTabId: workspace.id,
                        surfaceId: panel.id
                    ),
                    isManuallyUnread: workspace.manualUnreadPanelIds.contains(panel.id)
                )
                PanelContentView(
                    panel: panel,
                    workspaceId: workspace.id,
                    paneId: paneId,
                    isFocused: isFocused,
                    isSelectedInPane: isSelectedInPane,
                    isVisibleInUI: isVisibleInUI,
                    portalPriority: portalPriority,
                    isSplit: isSplit,
                    appearance: appearance,
                    hasUnreadNotification: showsNotificationRing && !usesWorkspacePaneOverlay,
                    onFocus: {
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
                    onTriggerFlash: { workspace.triggerDebugFlash(panelId: panel.id) }
                )
                .onTapGesture {
                    dock.controller.focusPane(paneId)
                }
            } else {
                EmptyPanelView(workspace: workspace, paneId: paneId, controller: dock.controller)
            }
        } emptyPane: { paneId in
            EmptyPanelView(workspace: workspace, paneId: paneId, controller: dock.controller)
                .onTapGesture {
                    dock.controller.focusPane(paneId)
                }
        }
        .internalOnlyTabDrag()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var removeDockTitle: String {
        String(localized: "workspaceDock.remove", defaultValue: "Remove Dock")
    }

    private func addDockTitle(edge: WorkspaceDockEdge) -> String {
        switch edge {
        case .left:
            return String(localized: "workspaceDock.add.left", defaultValue: "Add Left Dock")
        case .right:
            return String(localized: "workspaceDock.add.right", defaultValue: "Add Right Dock")
        case .bottom:
            return String(localized: "workspaceDock.add.bottom", defaultValue: "Add Bottom Dock")
        }
    }
}

/// View shown for empty panes
private enum EmptyPaneCreationAction: Hashable, Identifiable {
    case builtIn(CmuxSurfaceTabBarBuiltInAction)
    case rightSidebarTool(RightSidebarMode)

    static var all: [EmptyPaneCreationAction] {
        [
            .builtIn(.newTerminal),
            .builtIn(.newBrowser),
        ] + RightSidebarMode.paneModes.map { .rightSidebarTool($0) }
    }

    var id: String {
        switch self {
        case .builtIn(let action):
            return action.configID
        case .rightSidebarTool(let mode):
            return "rightSidebarTool.\(mode.rawValue)"
        }
    }

    var title: String {
        switch self {
        case .builtIn(.newTerminal):
            return String(localized: "emptyPanel.action.terminal", defaultValue: "Terminal")
        case .builtIn(.newBrowser):
            return String(localized: "emptyPanel.action.browser", defaultValue: "Browser")
        case .builtIn:
            return ""
        case .rightSidebarTool(let mode):
            return mode.label
        }
    }

    var systemImage: String {
        switch self {
        case .builtIn(.newTerminal):
            return "terminal.fill"
        case .builtIn(let action):
            return action.defaultIcon
        case .rightSidebarTool(let mode):
            return mode.symbolName
        }
    }

    func shortcut(settingsRevision: UInt64) -> StoredShortcut? {
        _ = settingsRevision
        switch self {
        case .builtIn(.newTerminal):
            return KeyboardShortcutSettings.shortcut(for: .newSurface)
        case .builtIn(.newBrowser):
            return KeyboardShortcutSettings.shortcut(for: .openBrowser)
        case .builtIn, .rightSidebarTool:
            return nil
        }
    }

    var debugName: String {
        switch self {
        case .builtIn(.newTerminal):
            return "newTerminal"
        case .builtIn(.newBrowser):
            return "newBrowser"
        case .builtIn(let action):
            return action.configID
        case .rightSidebarTool(let mode):
            return "rightSidebarTool.\(mode.rawValue)"
        }
    }

    @MainActor
    func perform(
        workspace: Workspace,
        paneId: PaneID,
        controller: BonsplitController?
    ) -> Bool {
        (controller ?? workspace.bonsplitController).focusPane(paneId)
        switch self {
        case .builtIn(.newTerminal):
            return workspace.newTerminalSurface(inPane: paneId, controller: controller, focus: true) != nil
        case .builtIn(.newBrowser):
            return workspace.newBrowserSurface(inPane: paneId, controller: controller, focus: true) != nil
        case .builtIn:
            return false
        case .rightSidebarTool(let mode):
            return workspace.newRightSidebarToolSurface(
                inPane: paneId,
                controller: controller,
                mode: mode,
                focus: true
            ) != nil
        }
    }
}

struct EmptyPanelView: View {
    @ObservedObject var workspace: Workspace
    let paneId: PaneID
    let controller: BonsplitController?
    @ObservedObject private var keyboardShortcutSettingsObserver = KeyboardShortcutSettingsObserver.shared

    init(workspace: Workspace, paneId: PaneID, controller: BonsplitController? = nil) {
        self.workspace = workspace
        self.paneId = paneId
        self.controller = controller
    }

    private enum LauncherLayout: Equatable {
        case sideStack
        case bottomStrip
        case grid
        case iconGrid

        static func resolving(size: CGSize) -> LauncherLayout {
            if size.height <= 150 {
                return .bottomStrip
            }
            if size.width <= 140 {
                return .iconGrid
            }
            if size.width <= 260 {
                return .sideStack
            }
            return .grid
        }

        var showsText: Bool {
            switch self {
            case .iconGrid:
                return false
            case .sideStack, .bottomStrip, .grid:
                return true
            }
        }

        var showsShortcut: Bool {
            switch self {
            case .bottomStrip, .grid:
                return true
            case .sideStack, .iconGrid:
                return false
            }
        }
    }

    private struct ShortcutHint: View {
        let text: String

        var body: some View {
            Text(text)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.tertiary)
        }
    }

    private struct ActionButton: View {
        let action: EmptyPaneCreationAction
        let layout: LauncherLayout
        let shortcut: StoredShortcut?
        let perform: () -> Void
        @State private var isHovering = false

        private var minHeight: CGFloat {
            switch layout {
            case .bottomStrip:
                return 28
            case .grid, .sideStack:
                return 30
            case .iconGrid:
                return 28
            }
        }

        private var horizontalPadding: CGFloat {
            switch layout {
            case .bottomStrip, .grid:
                return 9
            case .sideStack:
                return 7
            case .iconGrid:
                return 0
            }
        }

        private var contentAlignment: Alignment {
            switch layout {
            case .sideStack:
                return .leading
            case .bottomStrip, .grid, .iconGrid:
                return .center
            }
        }

        var body: some View {
            Button(action: perform) {
                HStack(spacing: layout.showsText ? 6 : 0) {
                    Image(systemName: action.systemImage)
                        .font(.system(size: 13, weight: .medium))
                        .symbolRenderingMode(.hierarchical)
                    if layout.showsText {
                        Text(action.title)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.78)
                        if layout.showsShortcut, let shortcut {
                            Spacer(minLength: 4)
                            ShortcutHint(text: shortcut.displayString)
                        }
                    }
                }
                .frame(
                    maxWidth: layout == .bottomStrip ? nil : .infinity,
                    minHeight: minHeight,
                    alignment: contentAlignment
                )
                .padding(.horizontal, horizontalPadding)
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)
            .foregroundStyle(isHovering ? .primary : .secondary)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isHovering ? Color.primary.opacity(0.07) : Color.clear)
            )
            .accessibilityIdentifier("EmptyPanel.action.\(action.id)")
            .accessibilityLabel(action.title)
            .safeHelp(action.title)
            .onHover { hovering in
                isHovering = hovering
            }
        }
    }

    @ViewBuilder
    private func emptyPaneActionButton(
        for action: EmptyPaneCreationAction,
        layout: LauncherLayout
    ) -> some View {
        let shortcut = action.shortcut(settingsRevision: keyboardShortcutSettingsObserver.revision)
        let button = ActionButton(action: action, layout: layout, shortcut: shortcut) {
            #if DEBUG
            cmuxDebugLog("emptyPane.\(action.debugName) pane=\(paneId.id.uuidString.prefix(5))")
            #endif
            if !action.perform(workspace: workspace, paneId: paneId, controller: controller) {
                NSSound.beep()
            }
        }

        if let shortcut, let key = shortcut.keyEquivalent {
            button
            .keyboardShortcut(key, modifiers: shortcut.eventModifiers)
        } else {
            button
        }
    }

    @ViewBuilder
    private func launcherContent(layout: LauncherLayout) -> some View {
        switch layout {
        case .bottomStrip:
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(EmptyPaneCreationAction.all) { action in
                        emptyPaneActionButton(for: action, layout: layout)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
        case .sideStack:
            VStack(spacing: 4) {
                ForEach(EmptyPaneCreationAction.all) { action in
                    emptyPaneActionButton(for: action, layout: layout)
                }
            }
            .frame(maxWidth: 168)
            .padding(8)
        case .grid:
            LazyVGrid(
                columns: [
                    GridItem(.adaptive(minimum: 96, maximum: 132), spacing: 8, alignment: .center),
                ],
                spacing: 6
            ) {
                ForEach(EmptyPaneCreationAction.all) { action in
                    emptyPaneActionButton(for: action, layout: layout)
                }
            }
            .frame(maxWidth: 500)
            .padding(12)
        case .iconGrid:
            LazyVGrid(
                columns: [
                    GridItem(.adaptive(minimum: 30, maximum: 36), spacing: 4, alignment: .center),
                ],
                spacing: 4
            ) {
                ForEach(EmptyPaneCreationAction.all) { action in
                    emptyPaneActionButton(for: action, layout: layout)
                        .frame(width: 30)
                }
            }
            .frame(maxWidth: 92)
            .padding(6)
        }
    }

    var body: some View {
        GeometryReader { proxy in
            let layout = LauncherLayout.resolving(size: proxy.size)
            launcherContent(layout: layout)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
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
