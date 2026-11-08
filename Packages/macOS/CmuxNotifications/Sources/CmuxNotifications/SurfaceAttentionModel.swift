public import Foundation
import Observation

/// Main-actor source of truth for surfaces carrying owner-scoped visual attention.
@MainActor
@Observable
public final class SurfaceAttentionModel {
    /// Stable surface identifiers currently carrying attention.
    public private(set) var surfaceIds: Set<UUID>

    @ObservationIgnored
    private var observers: [UUID: (Set<UUID>) -> Bool] = [:]
    @ObservationIgnored
    private var pendingPublications: [Set<UUID>] = []
    @ObservationIgnored
    private var isPublishing = false

    /// Creates owner-scoped surface-attention state.
    ///
    /// - Parameter surfaceIds: The initially active stable surface identifiers.
    public init(surfaceIds: Set<UUID> = []) {
        self.surfaceIds = surfaceIds
    }

    /// Sets whether one stable surface carries attention.
    ///
    /// - Parameters:
    ///   - isActive: Whether the surface should carry attention.
    ///   - surfaceId: The stable surface identifier to mutate.
    /// - Returns: `true` when the stored state changed.
    @discardableResult
    public func setAttention(_ isActive: Bool, forSurfaceId surfaceId: UUID) -> Bool {
        var next = surfaceIds
        if isActive {
            next.insert(surfaceId)
        } else {
            next.remove(surfaceId)
        }
        return replace(with: next)
    }

    /// Replaces all active surface identifiers when the value changed.
    ///
    /// - Parameter surfaceIds: The authoritative replacement set.
    /// - Returns: `true` when the stored state changed.
    @discardableResult
    public func replace(with surfaceIds: Set<UUID>) -> Bool {
        guard self.surfaceIds != surfaceIds else { return false }
        self.surfaceIds = surfaceIds
        pendingPublications.append(surfaceIds)
        publishPendingValues()
        return true
    }

    /// Observes changed surface identifiers synchronously after publication.
    ///
    /// The model retains neither `owner` nor the returned cancellation token.
    ///
    /// - Parameters:
    ///   - owner: The weakly retained observation owner.
    ///   - receive: A callback invoked with each changed identifier set.
    /// - Returns: A token that can stop delivery before its lifetime ends.
    public func observeChanges<Owner: AnyObject>(
        owner: Owner,
        _ receive: @escaping @MainActor (Owner, Set<UUID>) -> Void
    ) -> SurfaceAttentionObservation {
        let id = UUID()
        let deliveryLifetime = ObservationDeliveryLifetime()
        observers[id] = { [weak owner, weak deliveryLifetime] surfaceIds in
            guard deliveryLifetime != nil, let owner else { return false }
            receive(owner, surfaceIds)
            return true
        }
        return SurfaceAttentionObservation(
            deliveryLifetime: deliveryLifetime,
            model: self,
            id: id
        )
    }

    private func publishPendingValues() {
        guard !isPublishing else { return }
        isPublishing = true
        defer {
            pendingPublications.removeAll(keepingCapacity: true)
            isPublishing = false
        }
        var publicationIndex = 0
        while publicationIndex < pendingPublications.count {
            let surfaceIds = pendingPublications[publicationIndex]
            publicationIndex += 1
            for id in Array(observers.keys) {
                guard let observer = observers[id] else { continue }
                if !observer(surfaceIds) {
                    observers[id] = nil
                }
            }
        }
    }

    func removeObserver(_ id: UUID) {
        observers[id] = nil
    }
}
