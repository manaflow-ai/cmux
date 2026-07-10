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
    @Bindable var panel: CustomSidebarPanel
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
            workspace.customSidebarWorkspaceSnapshot(
                index: index,
                selectedId: selectedId,
                unreadCount: sidebarUnread.unreadCount(forWorkspaceId: workspace.id)
            )
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
