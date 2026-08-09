public import Foundation
import Observation

/// Main-actor unread source of truth for leaf UI projections.
///
/// Global state publishes through ``snapshot``. Exact surface state publishes
/// through owner-keyed ``SidebarSurfaceUnreadProjection`` values so a mutation
/// cannot invalidate a different window or workspace by construction.
@MainActor
@Observable
public final class SidebarUnreadModel {
    private struct State: Equatable {
        var snapshot = SidebarUnreadSnapshot()
        var surfaceProjectionByOwnerId: [UUID: SidebarSurfaceUnreadProjection] = [:]
    }

    private struct Publication {
        let state: State
        let snapshotChanged: Bool
        let summaryChanged: Bool
        let changedSurfaceOwnerIds: [UUID]
    }

    /// The latest global unread state.
    public private(set) var snapshot = SidebarUnreadSnapshot()

    /// Total unread count rendered by global badges.
    public var totalUnreadCount: Int { snapshot.totalUnreadCount }
    /// Current per-workspace unread summaries.
    public var summaryByWorkspaceId: [UUID: SidebarWorkspaceUnreadSummary] {
        snapshot.summaryByWorkspaceId
    }
    /// Current notification-derived and owner-projected unread surface keys.
    public var unreadSurfaceKeys: Set<SidebarSurfaceUnreadKey> {
        var keys = snapshot.unreadSurfaceKeys
        for projection in surfaceProjectionByOwnerId.values {
            keys.formUnion(projection.unreadSurfaceIds.map {
                SidebarSurfaceUnreadKey(
                    workspaceId: projection.ownerId,
                    surfaceId: $0
                )
            })
        }
        return keys
    }
    /// Current focused read-indicator surfaces.
    public var focusedReadIndicatorByWorkspaceId: [UUID: UUID] {
        snapshot.focusedReadIndicatorByWorkspaceId
    }
    /// Workspaces explicitly marked unread.
    public var manualUnreadWorkspaceIds: Set<UUID> { snapshot.manualUnreadWorkspaceIds }

    @ObservationIgnored
    private var surfaceProjectionByOwnerId: [UUID: SidebarSurfaceUnreadProjection] = [:]
    @ObservationIgnored
    private var desiredState = State()
    @ObservationIgnored
    private var snapshotObservers: [UUID: (SidebarUnreadSnapshot) -> Bool] = [:]
    @ObservationIgnored
    private var summaryObservers: [UUID: (SidebarUnreadSnapshot) -> Bool] = [:]
    @ObservationIgnored
    private var surfaceObserversByOwnerId: [
        UUID: [UUID: (SidebarSurfaceUnreadProjection) -> Bool]
    ] = [:]
    @ObservationIgnored
    private var pendingPublications: [Publication] = []
    @ObservationIgnored
    private var isPublishing = false

    /// Creates an empty unread model.
    public init() {}

    /// Observes changed global snapshots synchronously after publication.
    ///
    /// The model retains neither `owner` nor the returned cancellation token.
    ///
    /// - Parameters:
    ///   - owner: The weakly retained observation owner.
    ///   - receive: A callback invoked for each changed global snapshot.
    /// - Returns: A token that can stop delivery before its lifetime ends.
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
        return SidebarUnreadObservation(model: self, id: id, channel: .snapshot)
    }

    /// Observes only changed per-workspace summaries.
    ///
    /// The delivered snapshot is the current global value, but changes limited
    /// to totals, focused indicators, or exact surfaces do not invoke this observer.
    ///
    /// - Parameters:
    ///   - owner: The weakly retained observation owner.
    ///   - receive: A callback invoked when workspace summaries change.
    /// - Returns: A token that can stop delivery before its lifetime ends.
    public func observeSummaryChanges<Owner: AnyObject>(
        owner: Owner,
        _ receive: @escaping @MainActor (Owner, SidebarUnreadSnapshot) -> Void
    ) -> SidebarUnreadObservation {
        let id = UUID()
        summaryObservers[id] = { [weak owner] snapshot in
            guard let owner else { return false }
            receive(owner, snapshot)
            return true
        }
        return SidebarUnreadObservation(model: self, id: id, channel: .summary)
    }

    /// Observes exact surface changes for one owner.
    ///
    /// A different owner changing never invokes this observer.
    ///
    /// - Parameters:
    ///   - ownerId: The workspace or window identifier whose surfaces are observed.
    ///   - owner: The weakly retained observation owner.
    ///   - receive: A callback invoked with the owner's changed projection.
    /// - Returns: A token that can stop delivery before its lifetime ends.
    public func observeSurfaceChanges<Owner: AnyObject>(
        forOwnerId ownerId: UUID,
        owner: Owner,
        _ receive: @escaping @MainActor (Owner, SidebarSurfaceUnreadProjection) -> Void
    ) -> SidebarUnreadObservation {
        let id = UUID()
        surfaceObserversByOwnerId[ownerId, default: [:]][id] = { [weak owner] projection in
            guard let owner else { return false }
            receive(owner, projection)
            return true
        }
        return SidebarUnreadObservation(
            model: self,
            id: id,
            channel: .surface(ownerId: ownerId)
        )
    }

    /// Atomically applies one complete unread state and publishes only changes.
    ///
    /// - Parameters:
    ///   - totalUnreadCount: The count rendered by global badges.
    ///   - summaries: Per-workspace row summaries.
    ///   - unreadSurfaceKeys: Notification-derived workspace and surface keys.
    ///   - focusedReadIndicatorByWorkspaceId: Focused read-indicator surfaces by owner.
    ///   - manualUnreadWorkspaceIds: Workspaces explicitly marked unread.
    ///   - manualUnreadSurfaceIdsByOwnerId: Owner-scoped manual unread surfaces.
    public func apply(
        totalUnreadCount: Int,
        summaries: [UUID: SidebarWorkspaceUnreadSummary],
        unreadSurfaceKeys: Set<SidebarSurfaceUnreadKey>,
        focusedReadIndicatorByWorkspaceId: [UUID: UUID],
        manualUnreadWorkspaceIds: Set<UUID>,
        manualUnreadSurfaceIdsByOwnerId: [UUID: Set<UUID>] = [:]
    ) {
        let nextSnapshot = SidebarUnreadSnapshot(
            totalUnreadCount: totalUnreadCount,
            summaryByWorkspaceId: summaries,
            unreadSurfaceKeys: unreadSurfaceKeys,
            focusedReadIndicatorByWorkspaceId: focusedReadIndicatorByWorkspaceId,
            manualUnreadWorkspaceIds: manualUnreadWorkspaceIds
        )
        enqueue(State(
            snapshot: nextSnapshot,
            surfaceProjectionByOwnerId: Self.makeSurfaceProjections(
                unreadSurfaceKeys: unreadSurfaceKeys,
                focusedReadIndicatorByOwnerId: focusedReadIndicatorByWorkspaceId,
                manualUnreadSurfaceIdsByOwnerId: manualUnreadSurfaceIdsByOwnerId
            )
        ))
    }

    /// Applies one exact surface projection without rebuilding unrelated state.
    ///
    /// Use this when the caller already maintains an incremental surface index,
    /// such as a per-window Dock BEL. A same-owner mutation that leaves the global
    /// total unchanged publishes only to that owner.
    ///
    /// - Parameters:
    ///   - key: The owner and exact surface pair whose effective state changed.
    ///   - isUnread: Whether the pair remains unread after combining all sources.
    ///   - totalUnreadCount: The authoritative global count after the mutation.
    public func applySurfaceUnreadProjection(
        _ key: SidebarSurfaceUnreadKey,
        isUnread: Bool,
        totalUnreadCount: Int
    ) {
        var next = desiredState
        if let surfaceId = key.surfaceId {
            var projection = next.surfaceProjectionByOwnerId[key.workspaceId]
                ?? SidebarSurfaceUnreadProjection(ownerId: key.workspaceId)
            var unreadSurfaceIds = projection.unreadSurfaceIds
            if isUnread {
                unreadSurfaceIds.insert(surfaceId)
            } else {
                unreadSurfaceIds.remove(surfaceId)
            }
            projection = SidebarSurfaceUnreadProjection(
                ownerId: key.workspaceId,
                unreadSurfaceIds: unreadSurfaceIds,
                focusedReadSurfaceId: projection.focusedReadSurfaceId
            )
            if projection.unreadSurfaceIds.isEmpty,
               projection.focusedReadSurfaceId == nil {
                next.surfaceProjectionByOwnerId[key.workspaceId] = nil
            } else {
                next.surfaceProjectionByOwnerId[key.workspaceId] = projection
            }
        } else {
            var unreadSurfaceKeys = next.snapshot.unreadSurfaceKeys
            if isUnread {
                unreadSurfaceKeys.insert(key)
            } else {
                unreadSurfaceKeys.remove(key)
            }
            next.snapshot = SidebarUnreadSnapshot(
                totalUnreadCount: next.snapshot.totalUnreadCount,
                summaryByWorkspaceId: next.snapshot.summaryByWorkspaceId,
                unreadSurfaceKeys: unreadSurfaceKeys,
                focusedReadIndicatorByWorkspaceId: next.snapshot.focusedReadIndicatorByWorkspaceId,
                manualUnreadWorkspaceIds: next.snapshot.manualUnreadWorkspaceIds
            )
        }
        if next.snapshot.totalUnreadCount != totalUnreadCount {
            next.snapshot = SidebarUnreadSnapshot(
                totalUnreadCount: totalUnreadCount,
                summaryByWorkspaceId: next.snapshot.summaryByWorkspaceId,
                unreadSurfaceKeys: next.snapshot.unreadSurfaceKeys,
                focusedReadIndicatorByWorkspaceId: next.snapshot.focusedReadIndicatorByWorkspaceId,
                manualUnreadWorkspaceIds: next.snapshot.manualUnreadWorkspaceIds
            )
        }
        enqueue(next)
    }

    /// Applies one workspace summary and global total incrementally.
    ///
    /// - Parameters:
    ///   - workspaceId: The workspace whose summary changed.
    ///   - summary: The new summary, or `nil` to remove the default-empty entry.
    ///   - totalUnreadCount: The authoritative global count after the mutation.
    public func applyWorkspaceSummaryProjection(
        forWorkspaceId workspaceId: UUID,
        summary: SidebarWorkspaceUnreadSummary?,
        totalUnreadCount: Int
    ) {
        var next = desiredState
        var summaries = next.snapshot.summaryByWorkspaceId
        summaries[workspaceId] = summary
        next.snapshot = SidebarUnreadSnapshot(
            totalUnreadCount: totalUnreadCount,
            summaryByWorkspaceId: summaries,
            unreadSurfaceKeys: next.snapshot.unreadSurfaceKeys,
            focusedReadIndicatorByWorkspaceId: next.snapshot.focusedReadIndicatorByWorkspaceId,
            manualUnreadWorkspaceIds: next.snapshot.manualUnreadWorkspaceIds
        )
        enqueue(next)
    }

    /// Returns the exact surface projection for one owner.
    ///
    /// - Parameter ownerId: The workspace or window identifier to query.
    /// - Returns: The current projection, or an empty projection for the owner.
    public func surfaceProjection(forOwnerId ownerId: UUID) -> SidebarSurfaceUnreadProjection {
        surfaceProjectionByOwnerId[ownerId]
            ?? SidebarSurfaceUnreadProjection(ownerId: ownerId)
    }

    private static func makeSurfaceProjections(
        unreadSurfaceKeys: Set<SidebarSurfaceUnreadKey>,
        focusedReadIndicatorByOwnerId: [UUID: UUID],
        manualUnreadSurfaceIdsByOwnerId: [UUID: Set<UUID>]
    ) -> [UUID: SidebarSurfaceUnreadProjection] {
        var unreadSurfaceIdsByOwnerId = manualUnreadSurfaceIdsByOwnerId.filter {
            !$0.value.isEmpty
        }
        for key in unreadSurfaceKeys {
            guard let surfaceId = key.surfaceId else { continue }
            unreadSurfaceIdsByOwnerId[key.workspaceId, default: []].insert(surfaceId)
        }
        var ownerIds = Set(unreadSurfaceIdsByOwnerId.keys)
        ownerIds.formUnion(focusedReadIndicatorByOwnerId.keys)
        var result: [UUID: SidebarSurfaceUnreadProjection] = [:]
        result.reserveCapacity(ownerIds.count)
        for ownerId in ownerIds {
            result[ownerId] = SidebarSurfaceUnreadProjection(
                ownerId: ownerId,
                unreadSurfaceIds: unreadSurfaceIdsByOwnerId[ownerId] ?? [],
                focusedReadSurfaceId: focusedReadIndicatorByOwnerId[ownerId]
            )
        }
        return result
    }

    private func enqueue(_ next: State) {
        let previous = desiredState
        guard previous != next else { return }
        let ownerIds = Set(previous.surfaceProjectionByOwnerId.keys)
            .union(next.surfaceProjectionByOwnerId.keys)
        let changedSurfaceOwnerIds = ownerIds.filter {
            previous.surfaceProjectionByOwnerId[$0]
                != next.surfaceProjectionByOwnerId[$0]
        }.sorted { $0.uuidString < $1.uuidString }
        desiredState = next
        pendingPublications.append(Publication(
            state: next,
            snapshotChanged: previous.snapshot != next.snapshot,
            summaryChanged: previous.snapshot.summaryByWorkspaceId
                != next.snapshot.summaryByWorkspaceId,
            changedSurfaceOwnerIds: changedSurfaceOwnerIds
        ))
        publishPendingState()
    }

    private func publishPendingState() {
        guard !isPublishing else { return }
        isPublishing = true
        defer {
            pendingPublications.removeAll(keepingCapacity: true)
            isPublishing = false
        }
        var publicationIndex = 0
        while publicationIndex < pendingPublications.count {
            let publication = pendingPublications[publicationIndex]
            publicationIndex += 1
            surfaceProjectionByOwnerId = publication.state.surfaceProjectionByOwnerId
            if publication.snapshotChanged {
                snapshot = publication.state.snapshot
            }
            for ownerId in publication.changedSurfaceOwnerIds {
                publishSurfaceProjection(forOwnerId: ownerId)
            }
            if publication.summaryChanged {
                publishSummaryObservers(publication.state.snapshot)
            }
            if publication.snapshotChanged {
                publishSnapshotObservers(publication.state.snapshot)
            }
        }
    }

    private func publishSurfaceProjection(forOwnerId ownerId: UUID) {
        guard let observers = surfaceObserversByOwnerId[ownerId] else { return }
        let observerIds = Array(observers.keys)
        let projection = surfaceProjection(forOwnerId: ownerId)
        for id in observerIds {
            guard let observer = surfaceObserversByOwnerId[ownerId]?[id] else { continue }
            if !observer(projection) {
                surfaceObserversByOwnerId[ownerId]?[id] = nil
            }
        }
        if surfaceObserversByOwnerId[ownerId]?.isEmpty == true {
            surfaceObserversByOwnerId[ownerId] = nil
        }
    }

    private func publishSummaryObservers(_ snapshot: SidebarUnreadSnapshot) {
        for id in Array(summaryObservers.keys) {
            guard let observer = summaryObservers[id] else { continue }
            if !observer(snapshot) {
                summaryObservers[id] = nil
            }
        }
    }

    private func publishSnapshotObservers(_ snapshot: SidebarUnreadSnapshot) {
        for id in Array(snapshotObservers.keys) {
            guard let observer = snapshotObservers[id] else { continue }
            if !observer(snapshot) {
                snapshotObservers[id] = nil
            }
        }
    }

    func removeObserver(_ id: UUID, channel: SidebarUnreadObservationChannel) {
        switch channel {
        case .snapshot:
            snapshotObservers[id] = nil
        case .summary:
            summaryObservers[id] = nil
        case .surface(let ownerId):
            surfaceObserversByOwnerId[ownerId]?[id] = nil
            if surfaceObserversByOwnerId[ownerId]?.isEmpty == true {
                surfaceObserversByOwnerId[ownerId] = nil
            }
        }
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

    /// Returns whether a workspace or surface has effective unread state.
    public func hasUnreadNotification(forWorkspaceId id: UUID, surfaceId: UUID?) -> Bool {
        if snapshot.hasUnreadNotification(forWorkspaceId: id, surfaceId: surfaceId) {
            return true
        }
        guard let surfaceId else { return false }
        return surfaceProjection(forOwnerId: id).hasUnread(surfaceId: surfaceId)
    }

    /// Returns whether a surface should show its notification indicator.
    public func hasVisibleNotificationIndicator(forWorkspaceId id: UUID, surfaceId: UUID?) -> Bool {
        if snapshot.hasVisibleNotificationIndicator(
            forWorkspaceId: id,
            surfaceId: surfaceId
        ) {
            return true
        }
        guard let surfaceId else { return false }
        return surfaceProjection(forOwnerId: id).hasVisibleIndicator(surfaceId: surfaceId)
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
