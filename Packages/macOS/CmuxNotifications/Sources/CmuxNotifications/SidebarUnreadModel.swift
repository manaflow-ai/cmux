public import Foundation
public import Combine

/// Lightweight observable that the workspace sidebar and `ContentView` observe
/// instead of `TerminalNotificationStore`. `TerminalNotificationStore` drives it
/// from its single `refreshUnreadPresentation()` coalescing hub with equality
/// guards, so notification activity that does not change any workspace's badge,
/// latest-text, per-surface unread, or read-indicator never fires
/// `objectWillChange` here. That is what stops high-frequency notification churn
/// from re-rendering the workspace list (issue #2586 class of sidebar re-render
/// spins). The query methods mirror the equivalent `TerminalNotificationStore`
/// reads exactly so callers can switch source without behavior change.
///
/// This stays an `ObservableObject` rather than migrating to `@Observable`: its
/// only consumer (`ContentView`) observes it through `@EnvironmentObject`, and
/// the manual `objectWillChange` coalescing (the equality-guarded `apply` plus
/// `setMemoryWarningWorkspaceIds`) is load-bearing for the #2586 re-render gate.
/// Converting to `@Observable` would change observation granularity and force a
/// behavior-affecting `@EnvironmentObject` → `@Environment` rewrite at the
/// app-side read sites, so it is deferred to a dedicated Observable-migration
/// change.
@MainActor
public final class SidebarUnreadModel: ObservableObject {
    /// Total unread count shown on the sidebar/dock aggregate.
    @Published public private(set) var totalUnreadCount: Int = 0
    /// Per-workspace unread summaries keyed by workspace id.
    @Published public private(set) var summaryByWorkspaceId: [UUID: SidebarWorkspaceUnreadSummary] = [:]
    /// Per-surface unread keys mirroring the store's unread set.
    @Published public private(set) var unreadSurfaceKeys: Set<SidebarSurfaceUnreadKey> = []
    /// Focused read-indicator surface keyed by workspace id.
    @Published public private(set) var focusedReadIndicatorByWorkspaceId: [UUID: UUID] = [:]
    /// Workspaces the user manually marked unread.
    @Published public private(set) var manualUnreadWorkspaceIds: Set<UUID> = []
    /// Workspaces with at least one pane over the runaway-memory threshold.
    /// Mirrored here so the sidebar re-renders the warning badge through the
    /// same coalesced observation path as unread state (snapshot-boundary rule).
    public private(set) var memoryWarningWorkspaceIds: Set<UUID> = []

    /// Creates an empty unread projection. Populated via ``apply(totalUnreadCount:summaries:unreadSurfaceKeys:focusedReadIndicatorByWorkspaceId:manualUnreadWorkspaceIds:)``.
    public init() {}

    /// Replaces the memory-warning workspace set, firing `objectWillChange` only
    /// when it actually changes.
    public func setMemoryWarningWorkspaceIds(_ ids: Set<UUID>) {
        if memoryWarningWorkspaceIds != ids {
            objectWillChange.send()
            memoryWarningWorkspaceIds = ids
        }
    }

    /// Whether the workspace has at least one pane over the memory threshold.
    public func hasMemoryWarning(forWorkspaceId id: UUID) -> Bool {
        memoryWarningWorkspaceIds.contains(id)
    }

    /// Applies a coalesced unread projection, mutating only the fields that
    /// changed so `@Published` republishes are minimal.
    public func apply(
        totalUnreadCount: Int,
        summaries: [UUID: SidebarWorkspaceUnreadSummary],
        unreadSurfaceKeys: Set<SidebarSurfaceUnreadKey>,
        focusedReadIndicatorByWorkspaceId: [UUID: UUID],
        manualUnreadWorkspaceIds: Set<UUID>
    ) {
        if self.totalUnreadCount != totalUnreadCount {
            self.totalUnreadCount = totalUnreadCount
        }
        if summaryByWorkspaceId != summaries {
            summaryByWorkspaceId = summaries
        }
        if self.unreadSurfaceKeys != unreadSurfaceKeys {
            self.unreadSurfaceKeys = unreadSurfaceKeys
        }
        if self.focusedReadIndicatorByWorkspaceId != focusedReadIndicatorByWorkspaceId {
            self.focusedReadIndicatorByWorkspaceId = focusedReadIndicatorByWorkspaceId
        }
        if self.manualUnreadWorkspaceIds != manualUnreadWorkspaceIds {
            self.manualUnreadWorkspaceIds = manualUnreadWorkspaceIds
        }
    }

    /// The workspace's unread summary, or a zero summary when absent.
    public func summary(forWorkspaceId id: UUID) -> SidebarWorkspaceUnreadSummary {
        summaryByWorkspaceId[id] ?? SidebarWorkspaceUnreadSummary(unreadCount: 0, latestNotificationText: nil)
    }

    /// The workspace's unread count.
    public func unreadCount(forWorkspaceId id: UUID) -> Int {
        summary(forWorkspaceId: id).unreadCount
    }

    /// The workspace's latest-notification text.
    public func latestNotificationText(forWorkspaceId id: UUID) -> String? {
        summary(forWorkspaceId: id).latestNotificationText
    }

    /// Whether the workspace has any unread notifications.
    public func workspaceIsUnread(forWorkspaceId id: UUID) -> Bool {
        unreadCount(forWorkspaceId: id) > 0
    }

    /// Whether the workspace was manually marked unread.
    public func hasManualUnread(forWorkspaceId id: UUID) -> Bool {
        manualUnreadWorkspaceIds.contains(id)
    }

    /// Whether the workspace/surface pair has an unread notification.
    public func hasUnreadNotification(forWorkspaceId id: UUID, surfaceId: UUID?) -> Bool {
        unreadSurfaceKeys.contains(SidebarSurfaceUnreadKey(workspaceId: id, surfaceId: surfaceId))
    }

    /// Whether the workspace/surface pair shows a visible notification
    /// indicator (unread, or the focused read indicator).
    public func hasVisibleNotificationIndicator(forWorkspaceId id: UUID, surfaceId: UUID?) -> Bool {
        hasUnreadNotification(forWorkspaceId: id, surfaceId: surfaceId) ||
            (focusedReadIndicatorByWorkspaceId[id].map { $0 == surfaceId } ?? false)
    }

    /// Whether any of the workspaces can be marked read (at least one unread).
    public func canMarkWorkspaceRead(forWorkspaceIds ids: [UUID]) -> Bool {
        ids.contains { workspaceIsUnread(forWorkspaceId: $0) }
    }

    /// Whether any of the workspaces can be marked unread (at least one read).
    public func canMarkWorkspaceUnread(forWorkspaceIds ids: [UUID]) -> Bool {
        ids.contains { !workspaceIsUnread(forWorkspaceId: $0) }
    }
}
