import CmuxAppKitSupportUI
import CmuxSettings
import CmuxSettingsUI
import CmuxSidebar
import CmuxSidebarInterpreterClient
import CmuxSidebarRemoteRender
import CmuxSwiftRender
import CmuxSwiftRenderUI
import SwiftUI

struct CustomSidebarPanelView: View {
    @ObservedObject var panel: CustomSidebarPanel
    let tabManager: TabManager
    let sidebarUnread: SidebarUnreadModel
    let isFocused: Bool
    let isVisibleInUI: Bool
    let appearance: PanelAppearance
    let windowAppearance: WindowAppearanceSnapshot
    let onRequestPanelFocus: () -> Void

    @LiveSetting(\.customSidebars.renderer) private var customSidebarRenderer
    @State private var renderWorkerClient: RenderWorkerClient?
    @State private var focusFlashStartedAt: Date?
    @State private var completedFocusFlashStartedAt: Date?

    var body: some View {
        Group {
            if isVisibleInUI {
                TimelineView(.periodic(from: .now, by: 1)) { timeline in
                    CustomSidebarSurface(
                        fileURL: panel.fileURL,
                        dataContext: customSidebarDataContext(now: timeline.date),
                        dispatch: makeCmuxSidebarActionDispatch(),
                        contentInsets: CustomSidebarContentInsets.zero,
                        rendersInProcess: customSidebarRenderer == .inProcess,
                        client: $renderWorkerClient
                    )
                }
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(sidebarBackdrop)
        .environment(\.colorScheme, windowAppearance.sidebarContentColorScheme)
        .background(
            RightSidebarToolFocusAnchor(onViewChange: panel.attachFocusAnchor)
                .frame(width: 0, height: 0)
        )
        .overlay {
            focusFlashOverlay
        }
        .simultaneousGesture(TapGesture().onEnded { requestPanelFocusIfNeeded() })
        .onChange(of: panel.focusFlashToken) { _, _ in
            focusFlashStartedAt = Date()
        }
        .onChange(of: isVisibleInUI) { _, visible in
            if !visible {
                shutdownRenderWorkerClient()
            }
        }
        .onChange(of: customSidebarRenderer) { _, renderer in
            if renderer == .inProcess {
                shutdownRenderWorkerClient()
            }
        }
        .onDisappear {
            shutdownRenderWorkerClient()
        }
    }

    private var sidebarBackdrop: some View {
        ZStack {
            Color(nsColor: appearance.backgroundColor)
            WindowBackdropLayer(role: .rightSidebar, snapshot: windowAppearance)
        }
        .clipShape(RoundedRectangle(cornerRadius: windowAppearance.sidebarSettings.materialPolicy.cornerRadius, style: .continuous))
    }

    private func shutdownRenderWorkerClient() {
        guard let client = renderWorkerClient else { return }
        renderWorkerClient = nil
        Task { await client.shutdown() }
    }

    private func customSidebarDataContext(now: Date) -> [String: SwiftValue] {
        CustomSidebarPaneDataContextCache.shared.dataContext(
            now: now,
            tabManager: tabManager,
            sidebarUnread: sidebarUnread
        ) {
            buildCustomSidebarDataContext(now: now)
        }
    }

    private func buildCustomSidebarDataContext(now: Date) -> [String: SwiftValue] {
        let selectedId = tabManager.selectedTabId
        let workspaces = tabManager.tabs.enumerated().map { index, workspace in
            customSidebarWorkspaceSnapshot(workspace, index: index, selectedId: selectedId)
        }
        let selectedWorkspace = tabManager.tabs.first { $0.id == selectedId }
        let snapshot = CustomSidebarContextSnapshot(
            workspaces: workspaces,
            selectedWorkspaceId: selectedId,
            selectedWorkspaceTitle: selectedWorkspace?.customTitle ?? selectedWorkspace?.title ?? "",
            totalUnreadCount: sidebarUnread.totalUnreadCount,
            now: now
        )
        return CustomSidebarDataContextBuilder().dataContext(for: snapshot)
    }

    private func customSidebarWorkspaceSnapshot(
        _ workspace: Workspace,
        index: Int,
        selectedId: UUID?
    ) -> CustomSidebarWorkspaceSnapshot {
        let focusedPanelId = workspace.focusedPanelId
        let firstBranch = workspace.sidebarGitBranchesInDisplayOrder().first
        let progress = workspace.progress.map {
            CustomSidebarWorkspaceSnapshot.Progress(value: $0.value, label: $0.label)
        }
        let remote = workspace.remoteDisplayTarget.map { target in
            CustomSidebarWorkspaceSnapshot.Remote(
                target: target,
                stateRawValue: workspace.remoteConnectionState.rawValue,
                isConnected: workspace.remoteConnectionState == .connected
            )
        }
        return CustomSidebarWorkspaceSnapshot(
            id: workspace.id,
            title: workspace.customTitle ?? workspace.title,
            isSelected: workspace.id == selectedId,
            isPinned: workspace.isPinned,
            index: index,
            directory: workspace.currentDirectory,
            listeningPorts: workspace.listeningPorts,
            unreadCount: sidebarUnread.unreadCount(forWorkspaceId: workspace.id),
            surfaces: customSidebarSurfaceSnapshots(workspace, focusedPanelId: focusedPanelId),
            surfaceCount: workspace.bonsplitController.allPaneIds.reduce(0) { $0 + workspace.bonsplitController.tabs(inPane: $1).count },
            customDescription: workspace.customDescription,
            customColor: workspace.customColor,
            gitBranch: firstBranch?.branch,
            gitIsDirty: firstBranch?.isDirty ?? false,
            pullRequestValues: workspace.customSidebarPullRequestValues(),
            progress: progress,
            latestConversationMessage: workspace.latestConversationMessage,
            latestSubmittedMessage: workspace.latestSubmittedMessage,
            latestSubmittedAt: workspace.latestSubmittedAt,
            remote: remote
        )
    }

    private func customSidebarSurfaceSnapshots(
        _ workspace: Workspace,
        focusedPanelId: UUID?
    ) -> [CustomSidebarSurfaceSnapshot] {
        var surfaces: [CustomSidebarSurfaceSnapshot] = []
        for paneId in workspace.bonsplitController.allPaneIds {
            for tab in workspace.bonsplitController.tabs(inPane: paneId) {
                guard let panelId = workspace.panelIdFromSurfaceId(tab.id) else { continue }
                let git = workspace.panelGitBranches[panelId]
                surfaces.append(CustomSidebarSurfaceSnapshot(
                    panelId: panelId,
                    title: tab.title,
                    isFocused: panelId == focusedPanelId,
                    isPinned: workspace.pinnedPanelIds.contains(panelId),
                    directory: workspace.panelDirectories[panelId],
                    gitBranch: git?.branch,
                    gitIsDirty: git?.isDirty ?? false,
                    listeningPorts: workspace.surfaceListeningPorts[panelId] ?? []
                ))
            }
        }
        return surfaces
    }

    private func requestPanelFocusIfNeeded() {
        guard !panel.isFocusedInWorkspace else { return }
        onRequestPanelFocus()
    }

    @ViewBuilder
    private var focusFlashOverlay: some View {
        if shouldAnimateFocusFlash, let focusFlashStartedAt {
            TimelineView(TmuxWorkspacePaneFlashTimelineSchedule(startDate: focusFlashStartedAt)) { timeline in
                WorkspaceAttentionFlashRingView(
                    opacity: FocusFlashPattern.opacity(at: timeline.date.timeIntervalSince(focusFlashStartedAt))
                )
                .onChange(of: timeline.date) { _, date in
                    if date.timeIntervalSince(focusFlashStartedAt) >= FocusFlashPattern.duration {
                        completedFocusFlashStartedAt = focusFlashStartedAt
                    }
                }
            }
        } else {
            Color.clear
        }
    }

    private var shouldAnimateFocusFlash: Bool {
        guard let focusFlashStartedAt else { return false }
        guard completedFocusFlashStartedAt != focusFlashStartedAt else { return false }
        return Date() <= focusFlashStartedAt.addingTimeInterval(FocusFlashPattern.duration)
    }
}
