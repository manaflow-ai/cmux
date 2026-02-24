import SwiftUI
import Foundation
import AppKit
import Bonsplit

/// View that renders a Workspace's content using BonsplitView
struct WorkspaceContentView: View {
    @ObservedObject var workspace: Workspace
    let isWorkspaceVisible: Bool
    let isWorkspaceInputActive: Bool
    let workspacePortalPriority: Int
    let onThemeRefreshRequest: ((
        _ reason: String,
        _ backgroundEventId: UInt64?,
        _ backgroundSource: String?,
        _ notificationPayloadHex: String?
    ) -> Void)?
    @State private var config = WorkspaceContentView.resolveGhosttyAppearanceConfig(reason: "stateInit")
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject var notificationStore: TerminalNotificationStore

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

        BonsplitView(controller: workspace.bonsplitController) { tab, paneId in
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
                let hasUnreadNotification = Workspace.shouldShowUnreadIndicator(
                    hasUnreadNotification: notificationStore.hasUnreadNotification(forTabId: workspace.id, surfaceId: panel.id),
                    isManuallyUnread: workspace.manualUnreadPanelIds.contains(panel.id)
                )
                PanelContentView(
                    panel: panel,
                    isFocused: isFocused,
                    isSelectedInPane: isSelectedInPane,
                    isVisibleInUI: isVisibleInUI,
                    portalPriority: workspacePortalPriority,
                    isSplit: isSplit,
                    appearance: appearance,
                    hasUnreadNotification: hasUnreadNotification,
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
    }

    private func syncBonsplitNotificationBadges() {
        let unreadFromNotifications: Set<UUID> = Set(
            notificationStore.notifications
                .filter { $0.tabId == workspace.id && !$0.isRead }
                .compactMap { $0.surfaceId }
        )
        let manualUnread = workspace.manualUnreadPanelIds

        for paneId in workspace.bonsplitController.allPaneIds {
            for tab in workspace.bonsplitController.tabs(inPane: paneId) {
                let panelId = workspace.panelIdFromSurfaceId(tab.id)
                let expectedKind = panelId.flatMap { workspace.panelKind(panelId: $0) }
                let expectedPinned = panelId.map { workspace.isPanelPinned($0) } ?? false
                let shouldShow = panelId.map { unreadFromNotifications.contains($0) || manualUnread.contains($0) } ?? false
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

    static func resolveGhosttyAppearanceConfig(
        reason: String = "unspecified",
        backgroundOverride: NSColor? = nil,
        loadConfig: () -> GhosttyConfig = GhosttyConfig.load,
        defaultBackground: () -> NSColor = { GhosttyApp.shared.defaultBackgroundColor }
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
        if GhosttyApp.shared.backgroundLogEnabled {
            GhosttyApp.shared.logBackground(
                "theme resolve reason=\(reason) loadedBg=\(loadedBackgroundHex) overrideBg=\(backgroundOverride?.hexString() ?? "nil") defaultBg=\(defaultBackgroundHex) finalBg=\(next.backgroundColor.hexString()) theme=\(next.theme ?? "nil")"
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
        let shouldRequestTitlebarRefresh = backgroundChanged || reason == "onAppear"
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
                handle.seekToEndOfFile()
                handle.write(line.data(using: .utf8)!)
                handle.closeFile()
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
    @AppStorage(KeyboardShortcutSettings.Action.newSurface.defaultsKey) private var newSurfaceShortcutData = Data()
    @AppStorage(KeyboardShortcutSettings.Action.openBrowser.defaultsKey) private var openBrowserShortcutData = Data()

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
        dlog("emptyPane.newTerminal pane=\(paneId.id.uuidString.prefix(5))")
        #endif
        focusPane()
        _ = workspace.newTerminalSurface(inPane: paneId)
    }

    private func createBrowser() {
        #if DEBUG
        dlog("emptyPane.newBrowser pane=\(paneId.id.uuidString.prefix(5))")
        #endif
        focusPane()
        _ = workspace.newBrowserSurface(inPane: paneId)
    }

    private var newSurfaceShortcut: StoredShortcut {
        decodeShortcut(from: newSurfaceShortcutData, fallback: KeyboardShortcutSettings.Action.newSurface.defaultShortcut)
    }

    private var openBrowserShortcut: StoredShortcut {
        decodeShortcut(from: openBrowserShortcutData, fallback: KeyboardShortcutSettings.Action.openBrowser.defaultShortcut)
    }

    private func decodeShortcut(from data: Data, fallback: StoredShortcut) -> StoredShortcut {
        guard !data.isEmpty,
              let shortcut = try? JSONDecoder().decode(StoredShortcut.self, from: data) else {
            return fallback
        }
        return shortcut
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
        .background(Color(nsColor: .windowBackgroundColor))
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
