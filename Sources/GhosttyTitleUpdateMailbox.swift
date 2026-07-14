import Foundation

/// Bounded latest-value mailbox shared by Ghostty's synchronous callback and
/// one asynchronous consumer. Retirement is retained as a per-surface barrier,
/// so a surface retired and reused before a drain is reset before its new title.
nonisolated struct GhosttyTitleUpdateMailbox: Sendable {
    struct SurfaceKey: Hashable, Sendable {
        let tabId: UUID
        let surfaceId: UUID
        let sourceSurfaceIdentifier: ObjectIdentifier
    }

    typealias PendingOperation = (retirement: SurfaceKey?, update: GhosttyTitleUpdate?)

    private var sequence: UInt64 = 0
    private var lastTitleBySurface: [SurfaceKey: String] = [:]
    private var pendingUpdates: [SurfaceKey: GhosttyTitleUpdate] = [:]
    private var pendingRetirements = Set<SurfaceKey>()

    mutating func submit(
        tabId: UUID,
        surfaceId: UUID,
        sourceSurfaceIdentifier: ObjectIdentifier,
        title: String
    ) -> Bool {
        let key = SurfaceKey(
            tabId: tabId,
            surfaceId: surfaceId,
            sourceSurfaceIdentifier: sourceSurfaceIdentifier
        )
        guard lastTitleBySurface[key] != title else { return false }
        lastTitleBySurface[key] = title
        sequence &+= 1
        let wasEmpty = pendingUpdates.isEmpty && pendingRetirements.isEmpty
        pendingUpdates[key] = GhosttyTitleUpdate(
            tabId: tabId,
            surfaceId: surfaceId,
            title: title,
            sourceSurfaceIdentifier: sourceSurfaceIdentifier,
            sequence: sequence
        )
        return wasEmpty
    }

    mutating func retire(
        tabId: UUID,
        surfaceId: UUID,
        sourceSurfaceIdentifier: ObjectIdentifier
    ) -> Bool {
        let key = SurfaceKey(
            tabId: tabId,
            surfaceId: surfaceId,
            sourceSurfaceIdentifier: sourceSurfaceIdentifier
        )
        guard lastTitleBySurface.removeValue(forKey: key) != nil else { return false }
        let wasEmpty = pendingUpdates.isEmpty && pendingRetirements.isEmpty
        pendingRetirements.insert(key)
        pendingUpdates.removeValue(forKey: key)
        return wasEmpty
    }

    mutating func takePendingOperations() -> [PendingOperation] {
        let updates = pendingUpdates
        let retirements = pendingRetirements
        pendingUpdates.removeAll(keepingCapacity: true)
        pendingRetirements.removeAll(keepingCapacity: true)
        let keys = Set(updates.keys).union(retirements)
        var operations: [PendingOperation] = []
        operations.reserveCapacity(keys.count)
        for key in keys {
            operations.append((
                retirement: retirements.contains(key) ? key : nil,
                update: updates[key]
            ))
        }
        return operations
    }
}
