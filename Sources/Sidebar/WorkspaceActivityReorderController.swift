import CmuxAgentJournal
import CmuxSettings
import CmuxWorkspaces
import Foundation

/// Applies the `agentActivity` mode of `app.reorderOnNotification`.
///
/// ``WorkspaceActivityReorderGate`` owns the decisions; this type supplies
/// the clock and each workspace's live context (pinned, selected, already on
/// top, sidebar interaction), and moves workspaces to the top of their pin
/// tier, including deferred moves once the pointer leaves the sidebar or a
/// cooldown ends. The `notifications` mode never reaches this type.
@MainActor
final class WorkspaceActivityReorderController {
    static let shared = WorkspaceActivityReorderController()

    /// How often a deferred move rechecks whether the sidebar interaction
    /// that blocked it has ended.
    static let interactionRecheckInterval: TimeInterval = 0.5

    private var gate: WorkspaceActivityReorderGate
    private var drainTimer: Timer?
    private let now: @MainActor () -> Date
    private let mode: @MainActor () -> WorkspaceAutoReorderMode
    private let isSidebarInteracting: @MainActor () -> Bool
    private let tabManagerForWorkspace: @MainActor (UUID) -> TabManager?

    init(
        cooldown: TimeInterval = WorkspaceActivityReorderGate.defaultCooldown,
        now: @escaping @MainActor () -> Date = { Date() },
        mode: @escaping @MainActor () -> WorkspaceAutoReorderMode = {
            UserDefaultsSettingsClient(defaults: .standard).value(for: SettingCatalog().app.reorderOnNotification)
        },
        isSidebarInteracting: @escaping @MainActor () -> Bool = { SidebarReorderInteractionState.shared.isInteracting },
        tabManagerForWorkspace: @escaping @MainActor (UUID) -> TabManager? = { AppDelegate.shared?.tabManagerFor(tabId: $0) }
    ) {
        self.gate = WorkspaceActivityReorderGate(cooldown: cooldown)
        self.now = now
        self.mode = mode
        self.isSidebarInteracting = isSidebarInteracting
        self.tabManagerForWorkspace = tabManagerForWorkspace
    }

    /// An admitted notification asked to reorder its workspace.
    func notificationRequestsReorder(workspaceId: UUID) {
        request(workspaceId: workspaceId, trigger: .notification)
    }

    /// A live agent event caused a meaningful lifecycle transition on a
    /// surface in this workspace.
    func agentActivity(_ activity: AgentLifecycleActivity, workspaceId: UUID) {
#if DEBUG
        cmuxDebugLog("workspace.activityReorder.agent workspace=\(workspaceId.uuidString.prefix(8)) activity=\(activity.rawValue)")
#endif
        request(workspaceId: workspaceId, trigger: .agentActivity)
    }

    /// Releases deferred moves that may run now. Also runs on a timer while
    /// any move is deferred.
    func drainPendingMoves() {
        drainTimer?.invalidate()
        drainTimer = nil
        let ready = gate.drain(mode: mode(), now: now()) { [self] workspaceId in
            context(for: workspaceId)
        }
        for workspaceId in ready {
            move(workspaceId)
        }
        scheduleDrainIfNeeded()
    }

    var pendingWorkspaceIds: Set<UUID> { gate.pendingWorkspaceIds }

    private func request(workspaceId: UUID, trigger: WorkspaceActivityReorderGate.Trigger) {
        let currentMode = mode()
        guard currentMode == .agentActivity else { return }
        guard let context = context(for: workspaceId) else { return }
        if gate.admit(workspaceId: workspaceId, trigger: trigger, mode: currentMode, context: context, now: now()) == .moveNow {
            move(workspaceId)
        }
        // Give other deferred moves a chance whenever anything happens.
        drainPendingMoves()
    }

    private func move(_ workspaceId: UUID) {
        tabManagerForWorkspace(workspaceId)?.moveTabToTopForNotification(workspaceId)
    }

    private func context(for workspaceId: UUID) -> WorkspaceActivityReorderGate.Context? {
        guard let manager = tabManagerForWorkspace(workspaceId),
              let workspace = manager.workspacesById[workspaceId] else { return nil }
        return WorkspaceActivityReorderGate.Context(
            isPinned: workspace.isPinned,
            isSelected: manager.selectedTabId == workspaceId,
            isAtTop: manager.isAtTopOfUnpinnedTier(workspaceId),
            isSidebarInteracting: isSidebarInteracting()
        )
    }

    private func scheduleDrainIfNeeded() {
        guard !gate.pendingWorkspaceIds.isEmpty else { return }
        let current = now()
        let recheck = current.addingTimeInterval(Self.interactionRecheckInterval)
        let cooldownEnd = gate.nextCooldownEnd(after: current)
        // Poll only while an interaction blocks a move; a move that only
        // waits on its cooldown wakes exactly when the cooldown ends.
        let fireAt = isSidebarInteracting() || cooldownEnd == nil
            ? min(cooldownEnd ?? recheck, recheck)
            : cooldownEnd ?? recheck
        let timer = Timer(fire: fireAt, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.drainPendingMoves()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        drainTimer = timer
    }
}
