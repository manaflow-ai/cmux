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
    @State private var config = GhosttyConfig.load()
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject var notificationStore: TerminalNotificationStore

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

        let barAtTop = workspace.barConfig?.position == .top
        let barAtBottom = workspace.barConfig?.position == .bottom

        VStack(spacing: 0) {
        if barAtTop {
            WorkspaceBarView(workspace: workspace)
        }

        BonsplitView(controller: workspace.bonsplitController) { tab, paneId in
            // Content for each tab in bonsplit
            let _ = Self.debugPanelLookup(tab: tab, workspace: workspace)
            if let panel = workspace.panel(for: tab.id) {
                let isFocused = isWorkspaceInputActive && workspace.focusedPanelId == panel.id
                let isSelectedInPane = workspace.bonsplitController.selectedTab(inPane: paneId)?.id == tab.id
                let isVisibleInUI = isWorkspaceVisible && isSelectedInPane
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
                        workspace.focusPanel(panel.id)
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
            workspace.applyGhosttyChrome(backgroundColor: GhosttyApp.shared.defaultBackgroundColor)
            // Apply workspace background override once the Metal surface layer is ready.
            // The layer doesn't exist until the view is in the window hierarchy, so
            // applyBackgroundColorOverride() during TabManager.init() is a no-op.
            if workspace.backgroundColorOverride != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak workspace] in
                    workspace?.applyBackgroundColorOverride()
                }
            }
        }
        .onChange(of: notificationStore.notifications) { _, _ in
            syncBonsplitNotificationBadges()
        }
        .onChange(of: workspace.manualUnreadPanelIds) { _, _ in
            syncBonsplitNotificationBadges()
        }
        .onReceive(NotificationCenter.default.publisher(for: .ghosttyConfigDidReload)) { _ in
            refreshGhosttyAppearanceConfig()
        }
        .onChange(of: colorScheme) { _, _ in
            // Keep split overlay color/opacity in sync with light/dark theme transitions.
            refreshGhosttyAppearanceConfig()
        }
        .onReceive(NotificationCenter.default.publisher(for: .ghosttyDefaultBackgroundDidChange)) { notification in
            // Skip global background changes if this workspace has its own override
            guard workspace.backgroundColorOverride == nil else { return }
            if let backgroundColor = notification.userInfo?[GhosttyNotificationKey.backgroundColor] as? NSColor {
                workspace.applyGhosttyChrome(backgroundColor: backgroundColor)
            } else {
                workspace.applyGhosttyChrome(backgroundColor: GhosttyApp.shared.defaultBackgroundColor)
            }
        }
        .onChange(of: workspace.backgroundColorOverride) { _, _ in
            workspace.applyBackgroundColorOverride()
        }

        if barAtBottom {
            WorkspaceBarView(workspace: workspace)
        }
        } // VStack
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

    private func refreshGhosttyAppearanceConfig() {
        let next = GhosttyConfig.load()
        config = next
        workspace.applyGhosttyChrome(from: next)
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

/// Color bar displayed at the top or bottom of a workspace's terminal area.
private struct WorkspaceBarView: View {
    @ObservedObject var workspace: Workspace

    private var barColor: Color {
        if let hex = workspace.accentColor, let nsColor = NSColor(hex: hex) {
            return Color(nsColor: nsColor).opacity(0.3)
        }
        return Color.accentColor.opacity(0.3)
    }

    private var accentDot: Color {
        if let hex = workspace.accentColor, let nsColor = NSColor(hex: hex) {
            return Color(nsColor: nsColor)
        }
        return Color.accentColor
    }

    var body: some View {
        if let bar = workspace.barConfig {
            HStack(spacing: 6) {
                Circle()
                    .fill(accentDot)
                    .frame(width: 6, height: 6)

                Text(workspace.customTitle ?? workspace.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white)

                if let text = bar.text, !text.isEmpty {
                    Text(text)
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.5))
                }

                Spacer()

                if let branch = workspace.gitBranch {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 9))
                        Text(branch.branch)
                            .font(.system(size: 10, design: .monospaced))
                        if branch.isDirty {
                            Circle()
                                .fill(.white.opacity(0.6))
                                .frame(width: 4, height: 4)
                        }
                    }
                    .foregroundColor(.white.opacity(0.5))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity)
            .background(barColor)
        }
    }
}

/// View shown for empty panes
struct EmptyPanelView: View {
    @ObservedObject var workspace: Workspace
    let paneId: PaneID

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

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "terminal.fill")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)

            Text("Empty Panel")
                .font(.headline)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button {
                    createTerminal()
                } label: {
                    HStack(spacing: 10) {
                        Label("Terminal", systemImage: "terminal.fill")
                        ShortcutHint(text: "⌘T")
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("t", modifiers: [.command])

                Button {
                    createBrowser()
                } label: {
                    HStack(spacing: 10) {
                        Label("Browser", systemImage: "globe")
                        ShortcutHint(text: "⌘⇧L")
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("l", modifiers: [.command, .shift])
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
