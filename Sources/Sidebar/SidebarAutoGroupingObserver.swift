import CmuxNotifications
import Foundation
import Observation

/// Owns the automatic Group By inputs for one window's workspace sidebar.
///
/// Grouping facts are read here, outside the sidebar body, so the body never
/// touches live workspace state (such as the Observable cloud binding) to draw
/// sections: it reads `inputs(for:mode:)` from this cache plus `revision`.
///
/// A workspace can move to another section (an agent starts, asks for input,
/// an unread arrives, an SSH host connects, a Cloud VM gets its name) without
/// anything else re-rendering the body. The sidebar forwards its existing
/// per-workspace publisher, agent-runtime and cloud-binding observations to
/// `scheduleRecompute(workspaceId:)`, and membership changes to
/// `scheduleFullRecompute()`. Status mode also follows unread summary changes
/// from the window's `SidebarUnreadModel`. Only dirty workspaces are re-read,
/// and `revision` bumps only when some input (section key or title) changed.
/// In manual mode every subscription is dropped and scheduled work is ignored.
@MainActor
@Observable
final class SidebarAutoGroupingObserver {
    /// Bumped when some workspace's grouping input changed. The body reads it.
    private(set) var revision: UInt64 = 0

    @ObservationIgnored private weak var tabManager: TabManager?
    @ObservationIgnored private weak var unreadModel: SidebarUnreadModel?
    @ObservationIgnored private var unreadObservation: SidebarUnreadObservation?
    @ObservationIgnored private var lastUnreadCounts: [UUID: Int] = [:]
    @ObservationIgnored private var inputsByWorkspaceId: [UUID: SidebarAutoGroupingInput] = [:]
    @ObservationIgnored private var inputsMode: SidebarGroupByMode = .manual
    @ObservationIgnored private var trackedMode: SidebarGroupByMode = .manual
    @ObservationIgnored private var dirtyWorkspaceIds: Set<UUID> = []
    @ObservationIgnored private var needsFullRecompute = false
    @ObservationIgnored private var recomputeTask: Task<Void, Never>?
    @ObservationIgnored private var modeObservationGeneration: UInt64 = 0

    /// Starts following one window. Safe to call again with the same window.
    func attach(tabManager: TabManager, unreadModel: SidebarUnreadModel) {
        if self.tabManager !== tabManager || self.unreadModel !== unreadModel {
            detach()
            self.tabManager = tabManager
            self.unreadModel = unreadModel
        }
        trackMode()
    }

    /// Stops every subscription and pending recompute.
    func detach() {
        modeObservationGeneration &+= 1
        stopAutomaticTracking()
        tabManager = nil
        unreadModel = nil
    }

    /// Grouping inputs for `tabs` in order. Cached inputs for the requested
    /// mode are used as is; a workspace the cache has not seen yet (it was
    /// just added) is read directly until the next recompute stores it.
    func inputs(for tabs: [Workspace], mode: SidebarGroupByMode) -> [SidebarAutoGroupingInput] {
        let cached = inputsMode == mode ? inputsByWorkspaceId : [:]
        let notificationStore = TerminalNotificationStore.shared
        return tabs.map { workspace in
            cached[workspace.id] ?? SidebarAutoGroupingInput(
                workspace: workspace,
                mode: mode,
                unreadCount: { notificationStore.unreadCount(forTabId: $0) }
            )
        }
    }

    /// Marks one workspace for a re-read on the next main-actor turn. A no-op
    /// in manual mode, so callers can forward every workspace change.
    func scheduleRecompute(workspaceId: UUID) {
        guard trackedMode.isAutomatic else { return }
        dirtyWorkspaceIds.insert(workspaceId)
        scheduleFlush()
    }

    /// Re-reads every workspace, for membership or settings changes.
    func scheduleFullRecompute() {
        guard trackedMode.isAutomatic else { return }
        needsFullRecompute = true
        scheduleFlush()
    }

    /// Applies pending work now. Internal so tests can drive it without a run loop.
    func flushPendingRecompute() {
        recomputeTask?.cancel()
        recomputeTask = nil
        defer {
            dirtyWorkspaceIds.removeAll()
            needsFullRecompute = false
        }
        guard trackedMode.isAutomatic, let tabManager else { return }
        var changed = false
        if needsFullRecompute || inputsMode != trackedMode {
            var next: [UUID: SidebarAutoGroupingInput] = [:]
            next.reserveCapacity(tabManager.tabs.count)
            for workspace in tabManager.tabs {
                next[workspace.id] = input(for: workspace)
            }
            changed = inputsMode != trackedMode || next != inputsByWorkspaceId
            inputsByWorkspaceId = next
            inputsMode = trackedMode
        } else {
            for workspaceId in dirtyWorkspaceIds {
                let next = tabManager.workspacesById[workspaceId].map { input(for: $0) }
                guard inputsByWorkspaceId[workspaceId] != next else { continue }
                inputsByWorkspaceId[workspaceId] = next
                changed = true
            }
        }
        if changed {
            revision &+= 1
        }
    }

    private func scheduleFlush() {
        guard recomputeTask == nil else { return }
        recomputeTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled else { return }
            self.recomputeTask = nil
            self.flushPendingRecompute()
        }
    }

    private func input(for workspace: Workspace) -> SidebarAutoGroupingInput {
        let notificationStore = TerminalNotificationStore.shared
        return SidebarAutoGroupingInput(
            workspace: workspace,
            mode: trackedMode,
            unreadCount: { notificationStore.unreadCount(forTabId: $0) }
        )
    }

    /// Re-arms itself on every mode change so switching to or from manual
    /// starts or stops the automatic subscriptions without the view's help.
    /// The generation retires chains left over from an earlier attach.
    private func trackMode() {
        modeObservationGeneration &+= 1
        let generation = modeObservationGeneration
        guard let state = tabManager?.sidebarGroupBy else { return }
        let mode = withObservationTracking {
            state.mode
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.modeObservationGeneration == generation else { return }
                self.trackMode()
            }
        }
        guard mode != trackedMode else { return }
        guard mode.isAutomatic else {
            stopAutomaticTracking()
            return
        }
        trackedMode = mode
        // Host never reads unread state, so only Status follows it.
        if mode == .status {
            startUnreadTracking()
        } else {
            stopUnreadTracking()
        }
        needsFullRecompute = true
        flushPendingRecompute()
    }

    private func startUnreadTracking() {
        guard unreadObservation == nil, let unreadModel else { return }
        lastUnreadCounts = unreadModel.snapshot.summaryByWorkspaceId.mapValues(\.unreadCount)
        unreadObservation = unreadModel.observeSummaryChanges(owner: self) { observer, snapshot in
            observer.unreadSummariesDidChange(snapshot)
        }
    }

    private func stopUnreadTracking() {
        unreadObservation?.cancel()
        unreadObservation = nil
        lastUnreadCounts = [:]
    }

    /// Marks only the workspaces whose unread count changed.
    private func unreadSummariesDidChange(_ snapshot: SidebarUnreadSnapshot) {
        let counts = snapshot.summaryByWorkspaceId.mapValues(\.unreadCount)
        for workspaceId in Set(counts.keys).union(lastUnreadCounts.keys)
        where counts[workspaceId] != lastUnreadCounts[workspaceId] {
            scheduleRecompute(workspaceId: workspaceId)
        }
        lastUnreadCounts = counts
    }

    private func stopAutomaticTracking() {
        trackedMode = .manual
        stopUnreadTracking()
        recomputeTask?.cancel()
        recomputeTask = nil
        dirtyWorkspaceIds.removeAll()
        needsFullRecompute = false
        inputsByWorkspaceId = [:]
        inputsMode = .manual
    }
}
