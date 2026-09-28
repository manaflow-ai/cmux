import CmuxNotifications
import Foundation
import Observation

/// Tells the workspace sidebar when an automatic Group By section changes.
///
/// The sidebar body regroups whenever it renders, but a workspace can move to
/// another section (an agent starts, asks for input, an unread arrives, an SSH
/// host connects) without anything that re-renders the body. This observer
/// recomputes the workspace to section-key map on those signals and bumps
/// `revision`, which the body reads, only when that map actually changed.
///
/// Triggers are events, not polling: the sidebar forwards its per-workspace
/// publisher, agent-runtime and cloud-binding observations through
/// `scheduleRecompute()`, and unread summary changes arrive from the window's
/// `SidebarUnreadModel`. In manual mode the unread subscription is dropped and
/// scheduled work is ignored.
@MainActor
@Observable
final class SidebarAutoGroupingObserver {
    /// Bumped when some workspace changed section. The sidebar body reads it.
    private(set) var revision: UInt64 = 0

    @ObservationIgnored private weak var tabManager: TabManager?
    @ObservationIgnored private weak var unreadModel: SidebarUnreadModel?
    @ObservationIgnored private var unreadObservation: SidebarUnreadObservation?
    @ObservationIgnored private var signature: [UUID: String] = [:]
    @ObservationIgnored private var trackedMode: SidebarGroupByMode = .manual
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

    /// Coalesces a section recompute onto the next main-actor turn. A no-op
    /// in manual mode, so callers can forward every workspace change.
    func scheduleRecompute() {
        guard trackedMode.isAutomatic, recomputeTask == nil else { return }
        recomputeTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled else { return }
            self.recomputeTask = nil
            self.recompute()
        }
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
        if mode.isAutomatic {
            // Host and Status keys differ, so a direct switch between the two
            // starts from a fresh baseline.
            trackedMode = mode
            startAutomaticTracking()
        } else {
            stopAutomaticTracking()
        }
    }

    private func startAutomaticTracking() {
        signature = currentSignature()
        guard unreadObservation == nil, let unreadModel else { return }
        unreadObservation = unreadModel.observeSummaryChanges(owner: self) { observer, _ in
            observer.scheduleRecompute()
        }
    }

    private func stopAutomaticTracking() {
        trackedMode = .manual
        unreadObservation?.cancel()
        unreadObservation = nil
        recomputeTask?.cancel()
        recomputeTask = nil
        signature = [:]
    }

    private func recompute() {
        let next = currentSignature()
        guard next != signature else { return }
        signature = next
        revision &+= 1
    }

    private func currentSignature() -> [UUID: String] {
        guard let tabManager else { return [:] }
        let grouping = SidebarAutoGrouping(mode: tabManager.sidebarGroupBy.mode)
        let notificationStore = TerminalNotificationStore.shared
        var result: [UUID: String] = [:]
        result.reserveCapacity(tabManager.tabs.count)
        for workspace in tabManager.tabs {
            let input = SidebarWorkspaceGroupingProjection.autoGroupingInput(
                for: workspace,
                unreadCount: { notificationStore.unreadCount(forTabId: $0) }
            )
            result[workspace.id] = grouping.sectionKey(for: input)
        }
        return result
    }
}
