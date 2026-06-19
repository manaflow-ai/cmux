import AppKit
import Combine
import CmuxSidebarInterpreterClient
import CmuxSidebarRemoteRender
import CmuxSidebar
import CmuxSettings
import CmuxSettingsUI
import CmuxSwiftRender
import CmuxSwiftRenderUI
import SwiftUI

@MainActor
final class CustomSidebarPanel: Panel, ObservableObject {
    let id: UUID
    let panelType: PanelType = .customSidebar
    let name: String
    let fileURL: URL

    @Published private(set) var focusFlashToken: Int = 0

    private weak var workspace: Workspace?

    init(workspace: Workspace, name: String, fileURL: URL) {
        self.id = UUID()
        self.name = name
        self.fileURL = fileURL
        self.workspace = workspace
    }

    var displayTitle: String { name }
    var displayIcon: String? { "wand.and.stars" }

    var isFocusedInWorkspace: Bool {
        workspace?.focusedPanelId == id
    }

    func reattach(to workspace: Workspace) {
        self.workspace = workspace
    }

    func close() {}
    func focus() {}
    func unfocus() {}

    func triggerFlash(reason: WorkspaceAttentionFlashReason) {
        _ = reason
        guard NotificationPaneFlashSettings.isEnabled() else { return }
        focusFlashToken += 1
    }
}

@MainActor
private final class CustomSidebarPaneDataContextCache {
    static let shared = CustomSidebarPaneDataContextCache()

    private var cachedKey: String?
    private var cachedContext: [String: SwiftValue]?

    func dataContext(
        now: Date,
        tabManager: TabManager,
        sidebarUnread: SidebarUnreadModel,
        build: () -> [String: SwiftValue]
    ) -> [String: SwiftValue] {
        let key = [
            String(Int(now.timeIntervalSince1970)),
            ObjectIdentifier(tabManager).debugDescription,
            tabManager.selectedTabId?.uuidString ?? "",
            tabManager.tabs.map { $0.id.uuidString }.joined(separator: ","),
            String(sidebarUnread.totalUnreadCount)
        ].joined(separator: "|")
        if key == cachedKey, let cachedContext {
            return cachedContext
        }
        let context = build()
        cachedKey = key
        cachedContext = context
        return context
    }
}

struct CustomSidebarPanelView: View {
    @ObservedObject var panel: CustomSidebarPanel
    let tabManager: TabManager
    let sidebarUnread: SidebarUnreadModel
    let isFocused: Bool
    let isVisibleInUI: Bool
    let appearance: PanelAppearance
    let onRequestPanelFocus: () -> Void

    @LiveSetting(\.customSidebars.renderer) private var customSidebarRenderer
    @State private var renderWorkerClient: RenderWorkerClient?
    @State private var focusFlashOpacity: Double = 0.0
    @State private var focusFlashAnimationGeneration: Int = 0

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
        .background(Color(nsColor: appearance.backgroundColor))
        .overlay {
            WorkspaceAttentionFlashRingView(opacity: focusFlashOpacity)
        }
        .simultaneousGesture(TapGesture().onEnded { requestPanelFocusIfNeeded() })
        .onChange(of: panel.focusFlashToken) { _, _ in
            triggerFocusFlashAnimation()
        }
        .onChange(of: isVisibleInUI) { _, visible in
            if !visible {
                shutdownRenderWorkerClient()
            }
        }
        .onDisappear {
            shutdownRenderWorkerClient()
        }
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

    private func triggerFocusFlashAnimation() {
        focusFlashAnimationGeneration &+= 1
        let generation = focusFlashAnimationGeneration
        focusFlashOpacity = FocusFlashPattern.values.first ?? 0

        for segment in FocusFlashPattern.segments {
            DispatchQueue.main.asyncAfter(deadline: .now() + segment.delay) {
                guard focusFlashAnimationGeneration == generation else { return }
                withAnimation(focusFlashAnimation(for: segment.curve, duration: segment.duration)) {
                    focusFlashOpacity = segment.targetOpacity
                }
            }
        }
    }

    private func focusFlashAnimation(for curve: FocusFlashCurve, duration: TimeInterval) -> Animation {
        switch curve {
        case .easeIn:
            return .easeIn(duration: duration)
        case .easeOut:
            return .easeOut(duration: duration)
        }
    }
}
