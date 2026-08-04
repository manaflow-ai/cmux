public import Foundation
import Observation

/// The unread values rendered for one workspace row.
public struct SidebarWorkspaceUnreadSummary: Equatable, Sendable {
    /// The workspace's displayed unread count.
    public var unreadCount: Int
    /// The trimmed body or title of the latest notification, when present.
    public var latestNotificationText: String?
    /// Whether the workspace has a latest notification that can be cleared.
    public var hasLatestNotification: Bool

    /// Creates one workspace unread summary.
    public init(
        unreadCount: Int,
        latestNotificationText: String?,
        hasLatestNotification: Bool = false
    ) {
        self.unreadCount = unreadCount
        self.latestNotificationText = latestNotificationText
        self.hasLatestNotification = hasLatestNotification
    }
}

/// A workspace and optional surface pair in the unread set.
public struct SidebarSurfaceUnreadKey: Hashable, Sendable {
    /// The owning workspace identifier.
    public var workspaceId: UUID
    /// The surface identifier, or `nil` for a workspace-wide notification.
    public var surfaceId: UUID?

    /// Creates one workspace or surface unread key.
    public init(workspaceId: UUID, surfaceId: UUID?) {
        self.workspaceId = workspaceId
        self.surfaceId = surfaceId
    }
}

/// One atomic unread-state publication shared by all presentation surfaces.
public struct SidebarUnreadSnapshot: Equatable, Sendable {
    /// Total unread count rendered by global badges.
    public let totalUnreadCount: Int
    /// Per-workspace row summaries, omitting default empty summaries.
    public let summaryByWorkspaceId: [UUID: SidebarWorkspaceUnreadSummary]
    /// Workspace and surface pairs with unread notifications.
    public let unreadSurfaceKeys: Set<SidebarSurfaceUnreadKey>
    /// Focused surfaces whose read indicator remains visible.
    public let focusedReadIndicatorByWorkspaceId: [UUID: UUID]
    /// Workspaces explicitly marked unread by the user.
    public let manualUnreadWorkspaceIds: Set<UUID>

    /// Creates one complete unread snapshot.
    public init(
        totalUnreadCount: Int = 0,
        summaryByWorkspaceId: [UUID: SidebarWorkspaceUnreadSummary] = [:],
        unreadSurfaceKeys: Set<SidebarSurfaceUnreadKey> = [],
        focusedReadIndicatorByWorkspaceId: [UUID: UUID] = [:],
        manualUnreadWorkspaceIds: Set<UUID> = []
    ) {
        self.totalUnreadCount = totalUnreadCount
        self.summaryByWorkspaceId = summaryByWorkspaceId
        self.unreadSurfaceKeys = unreadSurfaceKeys
        self.focusedReadIndicatorByWorkspaceId = focusedReadIndicatorByWorkspaceId
        self.manualUnreadWorkspaceIds = manualUnreadWorkspaceIds
    }

    /// Returns the workspace summary, or an empty summary when absent.
    public func summary(forWorkspaceId id: UUID) -> SidebarWorkspaceUnreadSummary {
        summaryByWorkspaceId[id] ?? SidebarWorkspaceUnreadSummary(
            unreadCount: 0,
            latestNotificationText: nil
        )
    }

    /// Returns the workspace's displayed unread count.
    public func unreadCount(forWorkspaceId id: UUID) -> Int {
        summary(forWorkspaceId: id).unreadCount
    }

    /// Returns the workspace's latest notification text.
    public func latestNotificationText(forWorkspaceId id: UUID) -> String? {
        summary(forWorkspaceId: id).latestNotificationText
    }

    /// Returns whether the workspace has any displayed unread state.
    public func workspaceIsUnread(forWorkspaceId id: UUID) -> Bool {
        unreadCount(forWorkspaceId: id) > 0 || hasManualUnread(forWorkspaceId: id)
    }

    /// Returns whether the workspace was explicitly marked unread.
    public func hasManualUnread(forWorkspaceId id: UUID) -> Bool {
        manualUnreadWorkspaceIds.contains(id)
    }

    /// Returns whether the workspace or surface has an unread notification.
    public func hasUnreadNotification(forWorkspaceId id: UUID, surfaceId: UUID?) -> Bool {
        unreadSurfaceKeys.contains(SidebarSurfaceUnreadKey(workspaceId: id, surfaceId: surfaceId))
    }

    /// Returns whether the surface should render its notification indicator.
    public func hasVisibleNotificationIndicator(forWorkspaceId id: UUID, surfaceId: UUID?) -> Bool {
        hasUnreadNotification(forWorkspaceId: id, surfaceId: surfaceId) ||
            (focusedReadIndicatorByWorkspaceId[id].map { $0 == surfaceId } ?? false)
    }

    /// Returns whether any supplied workspace can be marked read.
    public func canMarkWorkspaceRead(forWorkspaceIds ids: [UUID]) -> Bool {
        ids.contains { workspaceIsUnread(forWorkspaceId: $0) }
    }

    /// Returns whether any supplied workspace can be marked unread.
    public func canMarkWorkspaceUnread(forWorkspaceIds ids: [UUID]) -> Bool {
        ids.contains { !workspaceIsUnread(forWorkspaceId: $0) }
    }
}

/// Cancels one imperative unread-snapshot observation.
@MainActor
public final class SidebarUnreadObservation {
    nonisolated(unsafe) private weak var model: SidebarUnreadModel?
    nonisolated private let id: UUID

    fileprivate init(model: SidebarUnreadModel, id: UUID) {
        self.model = model
        self.id = id
    }

    /// Stops delivering snapshot changes.
    public func cancel() {
        model?.removeSnapshotObserver(id)
        model = nil
    }

    deinit {
        let model = model
        let id = id
        Task { @MainActor in
            model?.removeSnapshotObserver(id)
        }
    }
}

/// Main-actor unread source of truth for leaf UI projections.
///
/// Mutations publish one equality-guarded snapshot. SwiftUI tracks ``snapshot``
/// through Observation, while imperative consumers register weak-owner callbacks.
@MainActor
@Observable
public final class SidebarUnreadModel {
    /// The latest complete unread state.
    public private(set) var snapshot = SidebarUnreadSnapshot()

    /// Total unread count rendered by global badges.
    public var totalUnreadCount: Int { snapshot.totalUnreadCount }
    /// Current per-workspace unread summaries.
    public var summaryByWorkspaceId: [UUID: SidebarWorkspaceUnreadSummary] {
        snapshot.summaryByWorkspaceId
    }
    /// Current workspace and surface unread keys.
    public var unreadSurfaceKeys: Set<SidebarSurfaceUnreadKey> { snapshot.unreadSurfaceKeys }
    /// Current focused read-indicator surfaces.
    public var focusedReadIndicatorByWorkspaceId: [UUID: UUID] {
        snapshot.focusedReadIndicatorByWorkspaceId
    }
    /// Workspaces explicitly marked unread.
    public var manualUnreadWorkspaceIds: Set<UUID> { snapshot.manualUnreadWorkspaceIds }

    @ObservationIgnored
    private var snapshotObservers: [UUID: (SidebarUnreadSnapshot) -> Bool] = [:]
    @ObservationIgnored
    private var pendingSnapshots: [SidebarUnreadSnapshot] = []
    @ObservationIgnored
    private var isPublishingSnapshot = false

    /// Creates an empty unread model.
    public init() {}

    /// Observes changed snapshots synchronously after publication.
    ///
    /// The model retains neither `owner` nor the returned cancellation token.
    public func observeChanges<Owner: AnyObject>(
        owner: Owner,
        _ receive: @escaping @MainActor (Owner, SidebarUnreadSnapshot) -> Void
    ) -> SidebarUnreadObservation {
        let id = UUID()
        snapshotObservers[id] = { [weak owner] snapshot in
            guard let owner else { return false }
            receive(owner, snapshot)
            return true
        }
        return SidebarUnreadObservation(model: self, id: id)
    }

    /// Atomically applies one complete unread state and publishes only changes.
    public func apply(
        totalUnreadCount: Int,
        summaries: [UUID: SidebarWorkspaceUnreadSummary],
        unreadSurfaceKeys: Set<SidebarSurfaceUnreadKey>,
        focusedReadIndicatorByWorkspaceId: [UUID: UUID],
        manualUnreadWorkspaceIds: Set<UUID>
    ) {
        let next = SidebarUnreadSnapshot(
            totalUnreadCount: totalUnreadCount,
            summaryByWorkspaceId: summaries,
            unreadSurfaceKeys: unreadSurfaceKeys,
            focusedReadIndicatorByWorkspaceId: focusedReadIndicatorByWorkspaceId,
            manualUnreadWorkspaceIds: manualUnreadWorkspaceIds
        )
        guard (pendingSnapshots.last ?? snapshot) != next else { return }
        pendingSnapshots.append(next)
        guard !isPublishingSnapshot else { return }

        isPublishingSnapshot = true
        defer {
            pendingSnapshots.removeAll(keepingCapacity: true)
            isPublishingSnapshot = false
        }
        var publicationIndex = 0
        while publicationIndex < pendingSnapshots.count {
            let publication = pendingSnapshots[publicationIndex]
            publicationIndex += 1
            snapshot = publication
            for id in Array(snapshotObservers.keys) {
                guard let observer = snapshotObservers[id] else { continue }
                if !observer(publication) {
                    snapshotObservers[id] = nil
                }
            }
        }
    }

    fileprivate func removeSnapshotObserver(_ id: UUID) {
        snapshotObservers[id] = nil
    }

    /// Returns the summary for one workspace.
    public func summary(forWorkspaceId id: UUID) -> SidebarWorkspaceUnreadSummary {
        snapshot.summary(forWorkspaceId: id)
    }

    /// Returns the unread count for one workspace.
    public func unreadCount(forWorkspaceId id: UUID) -> Int {
        snapshot.unreadCount(forWorkspaceId: id)
    }

    /// Returns the latest notification text for one workspace.
    public func latestNotificationText(forWorkspaceId id: UUID) -> String? {
        snapshot.latestNotificationText(forWorkspaceId: id)
    }

    /// Returns whether one workspace is unread.
    public func workspaceIsUnread(forWorkspaceId id: UUID) -> Bool {
        snapshot.workspaceIsUnread(forWorkspaceId: id)
    }

    /// Returns whether one workspace was manually marked unread.
    public func hasManualUnread(forWorkspaceId id: UUID) -> Bool {
        snapshot.hasManualUnread(forWorkspaceId: id)
    }

    /// Returns whether a workspace or surface has an unread notification.
    public func hasUnreadNotification(forWorkspaceId id: UUID, surfaceId: UUID?) -> Bool {
        snapshot.hasUnreadNotification(forWorkspaceId: id, surfaceId: surfaceId)
    }

    /// Returns whether a surface should show its notification indicator.
    public func hasVisibleNotificationIndicator(forWorkspaceId id: UUID, surfaceId: UUID?) -> Bool {
        snapshot.hasVisibleNotificationIndicator(forWorkspaceId: id, surfaceId: surfaceId)
    }

    /// Returns whether any supplied workspace can be marked read.
    public func canMarkWorkspaceRead(forWorkspaceIds ids: [UUID]) -> Bool {
        snapshot.canMarkWorkspaceRead(forWorkspaceIds: ids)
    }

    /// Returns whether any supplied workspace can be marked unread.
    public func canMarkWorkspaceUnread(forWorkspaceIds ids: [UUID]) -> Bool {
        snapshot.canMarkWorkspaceUnread(forWorkspaceIds: ids)
    }
}
