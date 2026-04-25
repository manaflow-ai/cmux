import SwiftUI
import Foundation
import AppKit
import Bonsplit

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
    // Keep in sync with Bonsplit's tab bar height so the monitor only covers
    // the minimal-mode titlebar strip.
    static let minimalModeTopStripHeight: CGFloat = 30
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

struct TmuxWorkspacePaneOverlayView: View {
    let unreadRects: [CGRect]
    let flashRect: CGRect?
    let flashStartedAt: Date?
    let flashReason: WorkspaceAttentionFlashReason?

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, _ in
                for rect in unreadRects {
                    drawUnreadRing(in: &context, rect: rect)
                }

                guard let flashRect,
                      let flashStartedAt else { return }
                let elapsed = timeline.date.timeIntervalSince(flashStartedAt)
                let opacity = FocusFlashPattern.opacity(at: elapsed)
                guard opacity > 0.001 else { return }
                drawFlashRing(
                    in: &context,
                    rect: flashRect,
                    opacity: opacity,
                    reason: flashReason ?? .notificationArrival
                )
            }
        }
        .allowsHitTesting(false)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func drawUnreadRing(in context: inout GraphicsContext, rect: CGRect) {
        guard let path = ringPath(for: rect) else { return }
        var glowContext = context
        glowContext.addFilter(.shadow(color: Color.blue.opacity(0.35), radius: 3))
        glowContext.stroke(
            path,
            with: .color(Color.blue),
            style: StrokeStyle(lineWidth: PanelOverlayRingMetrics.lineWidth, lineJoin: .round)
        )
    }

    private func drawFlashRing(
        in context: inout GraphicsContext,
        rect: CGRect,
        opacity: Double,
        reason: WorkspaceAttentionFlashReason
    ) {
        guard let path = ringPath(for: rect) else { return }
        let presentation = WorkspaceAttentionCoordinator.flashStyle(for: reason)
        let strokeColor = Color(nsColor: presentation.accent.strokeColor)

        var glowContext = context
        glowContext.addFilter(
            .shadow(
                color: strokeColor.opacity(opacity * presentation.glowOpacity),
                radius: presentation.glowRadius
            )
        )
        glowContext.stroke(
            path,
            with: .color(strokeColor.opacity(opacity)),
            style: StrokeStyle(lineWidth: PanelOverlayRingMetrics.lineWidth, lineJoin: .round)
        )
    }

    private func ringPath(for rect: CGRect) -> Path? {
        guard rect.width > PanelOverlayRingMetrics.inset * 2,
              rect.height > PanelOverlayRingMetrics.inset * 2 else { return nil }
        return Path(
            roundedRect: PanelOverlayRingMetrics.pathRect(in: rect),
            cornerRadius: PanelOverlayRingMetrics.cornerRadius
        )
    }
}

/// View that renders a Workspace's content using BonsplitView
struct WorkspaceContentView: View {
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
        .onChange(of: notificationStore.notifications) { _, _ in
            syncBonsplitNotificationBadges()
        }
        .onChange(of: workspace.manualUnreadPanelIds) { _, _ in
            syncBonsplitNotificationBadges()
        }
        .onReceive(NotificationCenter.default.publisher(for: .ghosttyConfigDidReload)) { _ in
            GhosttyConfig.invalidateLoadCache()
            refreshGhosttyAppearanceConfig(reason: "ghosttyConfigDidReload")
        }
        .onChange(of: colorScheme) { oldValue, newValue in
            // Keep split overlay color/opacity in sync with light/dark theme transitions.
            refreshGhosttyAppearanceConfig(reason: "colorSchemeChanged:\(oldValue)->\(newValue)")
        }
        .onReceive(NotificationCenter.default.publisher(for: .ghosttyDefaultBackgroundDidChange)) { notification in
            let payloadHex = (notification.userInfo?[GhosttyNotificationKey.backgroundColor] as? NSColor)?.hexString() ?? "nil"
            let eventId = (notification.userInfo?[GhosttyNotificationKey.backgroundEventId] as? NSNumber)?.uint64Value
            let source = (notification.userInfo?[GhosttyNotificationKey.backgroundSource] as? String) ?? "nil"
            logTheme(
                "theme notification workspace=\(workspace.id.uuidString) event=\(eventId.map(String.init) ?? "nil") source=\(source) payload=\(payloadHex) appBg=\(GhosttyApp.shared.defaultBackgroundColor.hexString()) appOpacity=\(String(format: "%.3f", GhosttyApp.shared.defaultBackgroundOpacity))"
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
            if isMinimalMode && !isFullScreen {
                bonsplitView
                    .ignoresSafeArea(.container, edges: .top)
            } else {
                bonsplitView
            }
        }
    }

    private func syncBonsplitNotificationBadges() {
        let manualUnread = workspace.manualUnreadPanelIds

        for paneId in workspace.bonsplitController.allPaneIds {
            for tab in workspace.bonsplitController.tabs(inPane: paneId) {
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

    private static let tmuxWorkspacePaneTopChromeHeight: CGFloat = 30

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

    static func resolveGhosttyAppearanceConfig(
        reason: String = "unspecified",
        backgroundOverride: NSColor? = nil,
        loadConfig: () -> GhosttyConfig = { GhosttyConfig.load() },
        defaultBackground: () -> NSColor = { GhosttyApp.shared.defaultBackgroundColor },
        defaultBackgroundOpacity: () -> Double = { GhosttyApp.shared.defaultBackgroundOpacity }
    ) -> GhosttyConfig {
        var next = loadConfig()
        let loadedBackgroundHex = next.backgroundColor.hexString()
        let defaultBackgroundHex: String
        let resolvedBackground: NSColor

        if let backgroundOverride {
            resolvedBackground = backgroundOverride
            defaultBackgroundHex = "skipped"
        } else {
            let fallback = defaultBackground()
            resolvedBackground = fallback
            defaultBackgroundHex = fallback.hexString()
        }

        next.backgroundColor = resolvedBackground
        // Use the runtime opacity from the Ghostty engine, which may differ from the
        // file-level value parsed by GhosttyConfig.load().
        next.backgroundOpacity = defaultBackgroundOpacity()
        if GhosttyApp.shared.backgroundLogEnabled {
            GhosttyApp.shared.logBackground(
                "theme resolve reason=\(reason) loadedBg=\(loadedBackgroundHex) overrideBg=\(backgroundOverride?.hexString() ?? "nil") defaultBg=\(defaultBackgroundHex) finalBg=\(next.backgroundColor.hexString()) opacity=\(String(format: "%.3f", next.backgroundOpacity)) theme=\(next.theme ?? "nil")"
            )
        }
        return next
    }

    private func refreshGhosttyAppearanceConfig(
        reason: String,
        backgroundOverride: NSColor? = nil,
        backgroundEventId: UInt64? = nil,
        backgroundSource: String? = nil,
        notificationPayloadHex: String? = nil
    ) {
        let previousBackgroundHex = config.backgroundColor.hexString()
        let next = Self.resolveGhosttyAppearanceConfig(
            reason: reason,
            backgroundOverride: backgroundOverride
        )
        let eventLabel = backgroundEventId.map(String.init) ?? "nil"
        let sourceLabel = backgroundSource ?? "nil"
        let payloadLabel = notificationPayloadHex ?? "nil"
        let backgroundChanged = previousBackgroundHex != next.backgroundColor.hexString()
        let opacityChanged = abs(config.backgroundOpacity - next.backgroundOpacity) > 0.0001
        let shouldRequestTitlebarRefresh = backgroundChanged || opacityChanged || reason == "onAppear"
        logTheme(
            "theme refresh begin workspace=\(workspace.id.uuidString) reason=\(reason) event=\(eventLabel) source=\(sourceLabel) payload=\(payloadLabel) previousBg=\(previousBackgroundHex) nextBg=\(next.backgroundColor.hexString()) overrideBg=\(backgroundOverride?.hexString() ?? "nil")"
        )
        withTransaction(Transaction(animation: nil)) {
            config = next
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
        workspace.applyGhosttyChrome(from: next, reason: chromeReason)
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

/// View shown for empty panes
struct EmptyPanelView: View {
    @ObservedObject var workspace: Workspace
    let paneId: PaneID
    @ObservedObject private var keyboardShortcutSettingsObserver = KeyboardShortcutSettingsObserver.shared

    private struct ShortcutHint: View {
        let text: String

        var body: some View {
            Text(text)
                .cmuxFont(size: 11, weight: .semibold, design: .rounded)
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
        _ = workspace.newTerminalSurface(inPane: paneId)
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
                .cmuxFont(size: 48)
                .foregroundStyle(.tertiary)

            Text("Empty Panel")
                .cmuxFont(.headline)
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
