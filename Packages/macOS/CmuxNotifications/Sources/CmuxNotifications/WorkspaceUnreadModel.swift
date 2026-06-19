public import Foundation
import Observation

/// The per-workspace unread / attention-indicator sub-model.
///
/// Owns the unread state the legacy `Workspace` god object kept as loose
/// `@Published` stored properties (`manualUnreadPanelIds`,
/// `restoredUnreadPanelIndicators`, `manualUnreadMarkedAt`) plus the pure
/// state-transition logic that drove the per-panel bonsplit notification badge
/// and the workspace-derived unread flag (`markPanelUnread`, `markPanelRead`,
/// `clearUnreadAfterJump`, `clearManualUnread`,
/// `clearAllPanelUnreadIndicatorsForWorkspaceRead`,
/// `restorePanelUnreadIndicator`, `clearRestoredUnreadIndicator`,
/// `preferredUnreadPanelIdForJump`, the badge-sync family, and
/// `syncPanelDerivedWorkspaceUnread`).
///
/// `Workspace` owns one instance and forwards each former stored property
/// through a computed `get`/`set` pair and each former method through a
/// one-line forward, so every call site stays byte-identical. The live work the
/// transitions need (the panel set, the bonsplit tab badge, the workspace's
/// notification store) is reached through ``WorkspaceUnreadHosting``, conformed
/// by `Workspace` and injected via ``attach(host:)``.
///
/// Observer parity: the legacy properties were `@Published` on an
/// `ObservableObject`, so SwiftUI views reading `workspace.manualUnreadPanelIds`
/// / `workspace.restoredUnreadPanelIds` re-rendered when they changed. This
/// model is `@Observable`, but its owner is still `ObservableObject`, so on
/// every state mutation it calls ``willChange`` (set by `Workspace` to
/// `objectWillChange.send()`) at `willSet` time, reproducing the `@Published`
/// emission moment. The legacy `didSet` that re-derived the workspace-unread
/// flag (guarded by `!= oldValue`) is preserved verbatim.
@MainActor
@Observable
public final class WorkspaceUnreadModel {
    /// Panels the user manually marked unread (legacy
    /// `Workspace.manualUnreadPanelIds`).
    public var manualUnreadPanelIds: Set<UUID> = [] {
        willSet { willChange?() }
        didSet {
            guard manualUnreadPanelIds != oldValue else { return }
            syncPanelDerivedWorkspaceUnread()
        }
    }

    /// Restored-from-snapshot unread indicators keyed by panel id (legacy
    /// `Workspace.restoredUnreadPanelIndicators`).
    public var restoredUnreadPanelIndicators: [UUID: RestoredPanelUnreadIndicator] = [:] {
        willSet { willChange?() }
        didSet {
            guard restoredUnreadPanelIndicators != oldValue else { return }
            syncPanelDerivedWorkspaceUnread()
        }
    }

    /// When each panel was last manually marked unread, used to pick the most
    /// recent panel for jump-to-unread (legacy `Workspace.manualUnreadMarkedAt`).
    ///
    /// The legacy property was a plain stored `var` (not `@Published`), so it
    /// never fired `objectWillChange`; this property deliberately omits the
    /// ``willChange`` bridge to preserve that.
    public var manualUnreadMarkedAt: [UUID: Date] = [:]

    /// Panel ids that carry a restored unread indicator (legacy
    /// `Workspace.restoredUnreadPanelIds`).
    public var restoredUnreadPanelIds: Set<UUID> {
        Set(restoredUnreadPanelIndicators.keys)
    }

    /// Whether any restored indicator contributes to workspace-level unread
    /// (legacy `Workspace.hasWorkspaceContributingRestoredUnreadIndicator`).
    public var hasWorkspaceContributingRestoredUnreadIndicator: Bool {
        restoredUnreadPanelIndicators.values.contains { $0.contributesToWorkspaceUnread }
    }

    /// Forwards the owner's `objectWillChange.send()` so SwiftUI views observing
    /// the owning `ObservableObject` re-render on the same `willSet` moment the
    /// former `@Published` properties fired. `nil` until ``attach(host:)``.
    @ObservationIgnored
    public var willChange: (() -> Void)?

    @ObservationIgnored
    private weak var host: (any WorkspaceUnreadHosting)?

    /// Creates an unattached model. Call ``attach(host:)`` at the composition
    /// point before any unread state changes.
    public init() {}

    /// Injects the live-workspace seam. Set before the model mutates so the
    /// derived-unread propagation and badge sync reach the workspace.
    public func attach(host: any WorkspaceUnreadHosting) {
        self.host = host
    }

    // MARK: - Badge sync

    /// Recomputes and applies a single panel's bonsplit notification badge.
    /// Faithful lift of `Workspace.syncUnreadBadgeStateForPanel(_:)`.
    public func syncUnreadBadgeStateForPanel(_ panelId: UUID) {
        guard let host, host.workspaceUnreadPanelHasTab(panelId) else { return }
        let shouldShowUnread = Self.shouldShowUnreadIndicator(
            hasUnreadNotification: host.workspaceUnreadHasVisibleNotificationIndicator(panelId: panelId),
            hasPanelUnreadIndicator: manualUnreadPanelIds.contains(panelId) || restoredUnreadPanelIds.contains(panelId),
            isWorkspaceManuallyUnread: host.workspaceUnreadNotificationHasManualUnread(),
            isWorkspaceManualUnreadRepresentative: host.workspaceUnreadRepresentativePanelId() == panelId
        )
        host.workspaceUnreadApplyBadge(panelId: panelId, showsNotificationBadge: shouldShowUnread)
    }

    /// Recomputes every panel's badge. Faithful lift of
    /// `Workspace.syncUnreadBadgeStateForAllPanels()`.
    public func syncUnreadBadgeStateForAllPanels() {
        guard let host else { return }
        for panelId in host.workspaceUnreadPanelIds() {
            syncUnreadBadgeStateForPanel(panelId)
        }
    }

    /// Propagates the panel-derived workspace-unread flag to the notification
    /// store. Faithful lift of `Workspace.syncPanelDerivedWorkspaceUnread()`.
    public func syncPanelDerivedWorkspaceUnread() {
        host?.workspaceUnreadSetPanelDerivedUnread(
            !manualUnreadPanelIds.isEmpty ||
                hasWorkspaceContributingRestoredUnreadIndicator
        )
    }

    // MARK: - Mutations

    /// Marks a panel manually unread. Faithful lift of
    /// `Workspace.markPanelUnread(_:)`.
    public func markPanelUnread(_ panelId: UUID) {
        guard host?.workspaceUnreadPanelExists(panelId) == true else { return }
        let didClearRestored = restoredUnreadPanelIndicators.removeValue(forKey: panelId) != nil
        let didInsertManual = manualUnreadPanelIds.insert(panelId).inserted
        guard didInsertManual || didClearRestored else { return }
        manualUnreadMarkedAt[panelId] = Date()
        syncUnreadBadgeStateForPanel(panelId)
    }

    /// The panel to jump to when navigating to the next unread panel. Faithful
    /// lift of `Workspace.preferredUnreadPanelIdForJump()`.
    public func preferredUnreadPanelIdForJump() -> UUID? {
        let latestManualPanelId = manualUnreadMarkedAt
            .filter { manualUnreadPanelIds.contains($0.key) && (host?.workspaceUnreadPanelExists($0.key) == true) }
            .max { $0.value < $1.value }?
            .key
        if let latestManualPanelId {
            return latestManualPanelId
        }
        if let manualPanelId = manualUnreadPanelIds.first(where: { host?.workspaceUnreadPanelExists($0) == true }) {
            return manualPanelId
        }
        if let restoredPanelId = restoredUnreadPanelIds.first(where: { host?.workspaceUnreadPanelExists($0) == true }) {
            return restoredPanelId
        }
        return host?.workspaceUnreadRepresentativePanelId()
    }

    /// Marks a panel read, clearing manual and restored indicators. Faithful
    /// lift of `Workspace.markPanelRead(_:)`.
    public func markPanelRead(_ panelId: UUID) {
        guard let host, host.workspaceUnreadPanelExists(panelId) else { return }
        host.workspaceUnreadNotificationMarkRead(panelId: panelId)
        _ = clearManualUnreadState(panelId: panelId)
        let restoredIndicator = restoredUnreadPanelIndicators[panelId]
        let didClearRestored = clearRestoredUnreadIndicatorState(panelId: panelId)
        if didClearRestored,
           restoredIndicator?.contributesToWorkspaceUnread == true,
           !hasWorkspaceContributingRestoredUnreadIndicator {
            host.workspaceUnreadNotificationClearRestoredUnreadIndicator()
        }
        syncUnreadBadgeStateForPanel(panelId)
    }

    /// Clears unread state after a jump to a panel (or the whole workspace when
    /// no panel matches). Faithful lift of `Workspace.clearUnreadAfterJump(panelId:)`.
    public func clearUnreadAfterJump(panelId: UUID?) {
        if let panelId,
           manualUnreadPanelIds.contains(panelId) || restoredUnreadPanelIds.contains(panelId) {
            markPanelRead(panelId)
            return
        }
        host?.workspaceUnreadNotificationMarkReadWorkspace()
    }

    /// Clears a panel's manual and restored unread indicators. Faithful lift of
    /// `Workspace.clearManualUnread(panelId:)`.
    public func clearManualUnread(panelId: UUID) {
        let didRemoveManual = clearManualUnreadState(panelId: panelId)
        let didRemoveRestored = clearRestoredUnreadIndicatorState(panelId: panelId)
        guard didRemoveManual || didRemoveRestored else { return }
        syncUnreadBadgeStateForPanel(panelId)
    }

    /// Clears all per-panel unread indicators when the workspace is read.
    /// Faithful lift of `Workspace.clearAllPanelUnreadIndicatorsForWorkspaceRead()`.
    @discardableResult
    public func clearAllPanelUnreadIndicatorsForWorkspaceRead() -> Bool {
        let hadLocalUnreadIndicators = !manualUnreadPanelIds.isEmpty || !restoredUnreadPanelIds.isEmpty
        let affectedPanelIds = (host?.workspaceUnreadPanelIds() ?? [])
            .union(manualUnreadPanelIds)
            .union(restoredUnreadPanelIds)
        guard !affectedPanelIds.isEmpty else { return false }
        manualUnreadPanelIds.removeAll()
        restoredUnreadPanelIndicators.removeAll()
        manualUnreadMarkedAt.removeAll()
        for panelId in affectedPanelIds {
            syncUnreadBadgeStateForPanel(panelId)
        }
        return hadLocalUnreadIndicators
    }

    private func clearManualUnreadState(panelId: UUID) -> Bool {
        let didRemoveUnread = manualUnreadPanelIds.remove(panelId) != nil
        manualUnreadMarkedAt.removeValue(forKey: panelId)
        return didRemoveUnread
    }

    /// Restores a panel's unread indicator from a session snapshot. Faithful
    /// lift of `Workspace.restorePanelUnreadIndicator(_:contributesToWorkspaceUnread:)`.
    public func restorePanelUnreadIndicator(
        _ panelId: UUID,
        contributesToWorkspaceUnread: Bool = true
    ) {
        guard host?.workspaceUnreadPanelExists(panelId) == true else { return }
        let nextIndicator = RestoredPanelUnreadIndicator(
            contributesToWorkspaceUnread: contributesToWorkspaceUnread
        )
        guard restoredUnreadPanelIndicators[panelId] != nextIndicator else { return }
        restoredUnreadPanelIndicators[panelId] = nextIndicator
        syncUnreadBadgeStateForPanel(panelId)
    }

    /// Clears a panel's restored unread indicator. Faithful lift of
    /// `Workspace.clearRestoredUnreadIndicator(panelId:)`.
    public func clearRestoredUnreadIndicator(panelId: UUID) {
        let didRemoveUnread = clearRestoredUnreadIndicatorState(panelId: panelId)
        guard didRemoveUnread else { return }
        syncUnreadBadgeStateForPanel(panelId)
    }

    /// Whether a panel carries a restored unread indicator. Faithful lift of
    /// `Workspace.hasRestoredUnreadIndicator(panelId:)`.
    public func hasRestoredUnreadIndicator(panelId: UUID) -> Bool {
        restoredUnreadPanelIds.contains(panelId)
    }

    /// Whether a panel's restored indicator contributes to workspace unread, or
    /// `nil` when the panel has none. Faithful lift of
    /// `Workspace.restoredUnreadIndicatorContributesToWorkspace(panelId:)`.
    public func restoredUnreadIndicatorContributesToWorkspace(panelId: UUID) -> Bool? {
        restoredUnreadPanelIndicators[panelId]?.contributesToWorkspaceUnread
    }

    private func clearRestoredUnreadIndicatorState(panelId: UUID) -> Bool {
        restoredUnreadPanelIndicators.removeValue(forKey: panelId) != nil
    }

    /// Resolves whether a panel's tab should show the unread badge. Faithful
    /// lift of `Workspace.shouldShowUnreadIndicator(...)`.
    public static func shouldShowUnreadIndicator(
        hasUnreadNotification: Bool,
        hasPanelUnreadIndicator: Bool,
        isWorkspaceManuallyUnread: Bool = false,
        isWorkspaceManualUnreadRepresentative: Bool = false
    ) -> Bool {
        hasUnreadNotification ||
            hasPanelUnreadIndicator ||
            (isWorkspaceManuallyUnread && isWorkspaceManualUnreadRepresentative)
    }
}
