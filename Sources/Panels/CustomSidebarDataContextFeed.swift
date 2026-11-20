import Combine
import CmuxMobileHost
import CmuxNotifications
import CmuxSidebar
import CmuxSwiftRender
import CmuxSwiftRenderUI
import Foundation
import Observation
import SwiftUI

/// The workspace half of a custom sidebar's data context, refreshed when the
/// workspace state it projects changes instead of on a timer.
///
/// Custom sidebars used to rebuild the whole context (every workspace's
/// snapshot) inside a one-second `TimelineView`, which was also their only
/// way to notice changes: workspaces are `ObservableObject`s the sidebar's
/// parent view does not observe. With ~50 workspaces that rebuild and the
/// re-render it forced kept the main thread busy most of every second.
///
/// The feed subscribes to the signals the context is built from (the tab
/// manager, each workspace, the unread model and the agent-session registry),
/// coalesces bursts into one refresh per main-queue turn, rebuilds only the
/// workspaces that changed, and publishes a new context only when it differs.
/// The `clock` key is not live here; ``CustomSidebarLiveDataContext`` merges
/// it at the tick rate the sidebar needs.
@MainActor
@Observable
final class CustomSidebarDataContextFeed {
    /// Bumps when ``dataContext`` changes; views observe this.
    private var revision = 0

    @ObservationIgnored private let tabManager: TabManager
    @ObservationIgnored private let sidebarUnread: SidebarUnreadModel
    @ObservationIgnored private let agentRecords: @MainActor () -> [AgentChatSessionRecord]
    @ObservationIgnored private var context: [String: SwiftValue]?
    @ObservationIgnored private var snapshots: [UUID: CustomSidebarWorkspaceSnapshot] = [:]
    @ObservationIgnored private var dirtyWorkspaceIds: Set<UUID> = []
    @ObservationIgnored private var allWorkspacesDirty = true
    @ObservationIgnored private var refreshScheduled = false
    @ObservationIgnored private var activeCount = 0
    @ObservationIgnored private var tabManagerCancellable: AnyCancellable?
    @ObservationIgnored private var workspaceCancellables: [UUID: AnyCancellable] = [:]
    @ObservationIgnored private var agentObservation: Task<Void, Never>?
    @ObservationIgnored private var unreadObservationGeneration = 0

    init(
        tabManager: TabManager,
        sidebarUnread: SidebarUnreadModel,
        agentRecords: @escaping @MainActor () -> [AgentChatSessionRecord] = Workspace.customSidebarAgentRecords
    ) {
        self.tabManager = tabManager
        self.sidebarUnread = sidebarUnread
        self.agentRecords = agentRecords
    }

    /// The current context. Reading it from a view body subscribes the view
    /// to changes. The first read builds it synchronously so a sidebar never
    /// mounts with empty data.
    var dataContext: [String: SwiftValue] {
        _ = revision
        if let context { return context }
        let built = buildContext()
        context = built
        return built
    }

    /// Starts listening for changes. Balanced by ``deactivate()``; nested
    /// calls share one set of subscriptions.
    func activate() {
        activeCount += 1
        guard activeCount == 1 else { return }
        tabManagerCancellable = tabManager.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleRefresh() }
            }
        observeUnread()
        observeAgents()
        // Anything that changed while inactive is unknown: rebuild everything.
        allWorkspacesDirty = true
        refresh()
    }

    /// Stops listening once every ``activate()`` is balanced.
    func deactivate() {
        guard activeCount > 0 else { return }
        activeCount -= 1
        guard activeCount == 0 else { return }
        tabManagerCancellable = nil
        workspaceCancellables.removeAll()
        agentObservation?.cancel()
        agentObservation = nil
        unreadObservationGeneration += 1
        refreshScheduled = false
    }

    /// Rebuilds now if anything was marked changed, and publishes the result
    /// when it differs from the current context.
    func refresh() {
        refreshScheduled = false
        let next = buildContext()
        guard next != context else { return }
        context = next
        revision &+= 1
    }

    // MARK: - Change signals

    private func scheduleRefresh() {
        guard activeCount > 0, !refreshScheduled else { return }
        refreshScheduled = true
        // One refresh per main-queue turn, after the batch of willChange
        // notifications that triggered it has landed.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.refreshScheduled else { return }
                self.refresh()
            }
        }
    }

    private func markWorkspaceDirty(_ id: UUID) {
        dirtyWorkspaceIds.insert(id)
        scheduleRefresh()
    }

    private func syncWorkspaceSubscriptions(_ workspaces: [Workspace]) {
        guard activeCount > 0 else { return }
        let liveIds = Set(workspaces.map(\.id))
        for id in workspaceCancellables.keys where !liveIds.contains(id) {
            workspaceCancellables[id] = nil
        }
        for workspace in workspaces where workspaceCancellables[workspace.id] == nil {
            let id = workspace.id
            workspaceCancellables[id] = workspace.objectWillChange
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    MainActor.assumeIsolated { self?.markWorkspaceDirty(id) }
                }
        }
    }

    private func observeUnread() {
        unreadObservationGeneration += 1
        let generation = unreadObservationGeneration
        withObservationTracking {
            _ = sidebarUnread.snapshot
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.unreadObservationGeneration == generation else { return }
                self.scheduleRefresh()
                self.observeUnread()
            }
        }
    }

    private func observeAgents() {
        agentObservation?.cancel()
        guard let service = TerminalController.shared.agentChatTranscriptService else { return }
        let changes = service.sidebarChanges()
        agentObservation = Task { @MainActor [weak self] in
            var isFirst = true
            for await _ in changes {
                // The stream replays the current revision on subscribe;
                // activate() already rebuilt from it.
                if isFirst { isFirst = false; continue }
                guard let self else { return }
                self.allWorkspacesDirty = true
                self.scheduleRefresh()
            }
        }
    }

    // MARK: - Build

    private func buildContext() -> [String: SwiftValue] {
        let workspaces = tabManager.tabs
        syncWorkspaceSubscriptions(workspaces)
        let selectedId = tabManager.selectedTabId
        let unread = sidebarUnread.snapshot
        let rebuildAll = allWorkspacesDirty || activeCount == 0
        var records: [AgentChatSessionRecord]?
        var nextSnapshots: [UUID: CustomSidebarWorkspaceSnapshot] = [:]
        var ordered: [CustomSidebarWorkspaceSnapshot] = []
        ordered.reserveCapacity(workspaces.count)
        for (index, workspace) in workspaces.enumerated() {
            let unreadCount = unread.unreadCount(forWorkspaceId: workspace.id)
            let snapshot: CustomSidebarWorkspaceSnapshot
            if !rebuildAll,
               !dirtyWorkspaceIds.contains(workspace.id),
               let cached = snapshots[workspace.id],
               cached.index == index,
               cached.isSelected == (workspace.id == selectedId),
               cached.unreadCount == unreadCount {
                snapshot = cached
            } else {
                if records == nil { records = agentRecords() }
                snapshot = workspace.customSidebarWorkspaceSnapshot(
                    index: index,
                    selectedId: selectedId,
                    unreadCount: unreadCount,
                    agentRecords: records
                )
            }
            nextSnapshots[workspace.id] = snapshot
            ordered.append(snapshot)
        }
        snapshots = nextSnapshots
        dirtyWorkspaceIds.removeAll()
        allWorkspacesDirty = false
        let selectedWorkspace = workspaces.first { $0.id == selectedId }
        return ContentView.customSidebarDataContext(
            workspaces: ordered,
            workspaceGroups: tabManager.workspaceGroups,
            selectedWorkspaceId: selectedId,
            selectedWorkspaceTitle: selectedWorkspace?.customTitle ?? selectedWorkspace?.title ?? "",
            totalUnreadCount: unread.totalUnreadCount,
            // Placeholder; the live clock is merged per tick.
            now: Date(timeIntervalSince1970: 0)
        )
    }
}

/// Feeds a custom sidebar surface its data context: workspace data from a
/// ``CustomSidebarDataContextFeed`` (re-renders only on change) plus the
/// `clock`, which ticks every second only when the sidebar's source reads it.
struct CustomSidebarLiveDataContext<Content: View>: View {
    @State private var feed: CustomSidebarDataContextFeed
    private let fileURL: URL
    private let sourceOverride: String?
    private let content: ([String: SwiftValue]) -> Content

    init(
        tabManager: TabManager,
        sidebarUnread: SidebarUnreadModel,
        fileURL: URL,
        sourceOverride: String? = nil,
        @ViewBuilder content: @escaping ([String: SwiftValue]) -> Content
    ) {
        _feed = State(initialValue: CustomSidebarDataContextFeed(
            tabManager: tabManager,
            sidebarUnread: sidebarUnread
        ))
        self.fileURL = fileURL
        self.sourceOverride = sourceOverride
        self.content = content
    }

    var body: some View {
        // Read here, not inside the timeline closure, so this body is what
        // observes the feed and a data change rebuilds the timeline content.
        let workspaceContext = feed.dataContext
        CustomSidebarClockTimeline(fileURL: fileURL, sourceOverride: sourceOverride) { now in
            content(CustomSidebarClock.dataContext(workspaceContext, at: now))
        }
        .onAppear { feed.activate() }
        .onDisappear { feed.deactivate() }
    }
}
