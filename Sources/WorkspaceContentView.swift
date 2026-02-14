import SwiftUI
import Foundation
import Bonsplit

/// View that renders a Workspace's content using BonsplitView
struct WorkspaceContentView: View {
    @ObservedObject var workspace: Workspace
    let isTabActive: Bool
    @State private var config = GhosttyConfig.load()
    @EnvironmentObject var notificationStore: TerminalNotificationStore

    var body: some View {
        let appearance = PanelAppearance.fromConfig(config)
        let isSplit = workspace.bonsplitController.allPaneIds.count > 1 ||
            workspace.panels.count > 1

        BonsplitView(controller: workspace.bonsplitController) { tab, paneId in
            // Content for each tab in bonsplit
            let _ = Self.debugPanelLookup(tab: tab, workspace: workspace)
            if let panel = workspace.panel(for: tab.id) {
                let isFocused = isTabActive && workspace.focusedPanelId == panel.id
                let isSelectedInPane = workspace.bonsplitController.selectedTab(inPane: paneId)?.id == tab.id
                let isVisibleInUI = isTabActive && isSelectedInPane
                PanelContentView(
                    panel: panel,
                    isFocused: isFocused,
                    isSelectedInPane: isSelectedInPane,
                    isVisibleInUI: isVisibleInUI,
                    isSplit: isSplit,
                    appearance: appearance,
                    notificationStore: notificationStore,
                    onFocus: {
                        // Keep bonsplit focus in sync with the AppKit first responder for the
                        // active workspace. This prevents divergence between the blue focused-tab
                        // indicator and where keyboard input/flash-focus actually lands.
                        guard isTabActive else { return }
                        guard workspace.panels[panel.id] != nil else { return }
                        workspace.focusPanel(panel.id)
                    },
                    onRequestPanelFocus: {
                        guard isTabActive else { return }
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
        }
        .onChange(of: notificationStore.notifications) { _, _ in
            syncBonsplitNotificationBadges()
        }
        .onReceive(NotificationCenter.default.publisher(for: .ghosttyConfigDidReload)) { _ in
            config = GhosttyConfig.load()
        }
    }

    private func syncBonsplitNotificationBadges() {
        let unreadPanelIds: Set<UUID> = Set(
            notificationStore.notifications
                .filter { $0.tabId == workspace.id && !$0.isRead }
                .compactMap { $0.surfaceId }
        )

        for paneId in workspace.bonsplitController.allPaneIds {
            for tab in workspace.bonsplitController.tabs(inPane: paneId) {
                let panelId = workspace.panelIdFromSurfaceId(tab.id)
                let shouldShow = panelId.map { unreadPanelIds.contains($0) } ?? false
                if tab.showsNotificationBadge != shouldShow {
                    workspace.bonsplitController.updateTab(tab.id, showsNotificationBadge: shouldShow)
                }
            }
        }
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
    #endif
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
        focusPane()
        _ = workspace.newTerminalSurface(inPane: paneId)
    }

    private func createBrowser() {
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
                        ShortcutHint(text: "⌘⇧B")
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("b", modifiers: [.command, .shift])
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
