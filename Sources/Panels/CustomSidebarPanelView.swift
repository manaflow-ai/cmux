import Combine
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
    // Data-context memoization, mirroring the window-level custom sidebar in
    // ContentView: the store rebuilds workspace snapshots only after a
    // coalesced invalidation; the 1 Hz TimelineView tick only re-derives the
    // cheap clock value. The publisher is memoized per workspace-id list so
    // `.onReceive` never re-subscribes every render (issue #5970).
    @State private var dataContextStore = CustomSidebarDataContextStore()
    @State private var dataContextRevision: UInt64 = 0
    @State private var observationWorkspaceIds: [UUID] = []
    @State private var observationPublisher: AnyPublisher<Void, Never> =
        Empty<Void, Never>().eraseToAnyPublisher()

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
        .onReceive(observationPublisher) { _ in
            invalidateDataContext()
        }
        .sidebarProcessTitleObservations(
            ids: tabManager.tabs.map(\.id),
            models: tabManager.tabs.map(\.sidebarProcessTitleObservation)
        ) {
            invalidateDataContext()
        }
        .onAppear {
            refreshObservationPublisher()
        }
        .onChange(of: tabManager.tabs.map(\.id)) { _, _ in
            refreshObservationPublisher()
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

    private func invalidateDataContext() {
        dataContextStore.invalidate()
        dataContextRevision &+= 1
    }

    private func refreshObservationPublisher() {
        let workspaceIds = tabManager.tabs.map(\.id)
        guard workspaceIds != observationWorkspaceIds else { return }
        observationWorkspaceIds = workspaceIds
        observationPublisher = CustomSidebarDataContextStore.invalidationPublisher(
            tabManager: tabManager,
            sidebarUnread: sidebarUnread,
            workspaces: tabManager.tabs
        )
    }

    private func customSidebarDataContext(now: Date) -> [String: SwiftValue] {
        let _ = dataContextRevision
        return dataContextStore.dataContext(now: now) {
            CustomSidebarDataContextStore.input(tabManager: tabManager, sidebarUnread: sidebarUnread)
        }
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
