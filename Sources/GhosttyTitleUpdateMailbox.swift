import Foundation

/// Bounded latest-value mailbox shared by Ghostty's synchronous callback and
/// one asynchronous consumer. Retirement is retained as a per-surface barrier,
/// so a surface retired and reused before a drain is reset before its new title.
nonisolated struct GhosttyTitleUpdateMailbox: Sendable {
    typealias PendingOperation = (retirement: GhosttyTitleUpdateSurfaceKey?, update: GhosttyTitleUpdate?)

    private var sequence: UInt64 = 0
    private var lastTitleBySurface: [GhosttyTitleUpdateSurfaceKey: String] = [:]
    private var pendingUpdates: [GhosttyTitleUpdateSurfaceKey: GhosttyTitleUpdate] = [:]
    private var pendingRetirements = Set<GhosttyTitleUpdateSurfaceKey>()

    mutating func submit(
        tabId: UUID,
        surfaceId: UUID,
        sourceSurfaceIdentifier: ObjectIdentifier,
        title: String
    ) -> Bool {
        let surfaceKey = GhosttyTitleUpdateSurfaceKey(
            surfaceId: surfaceId,
            sourceSurfaceIdentifier: sourceSurfaceIdentifier
        )
        guard lastTitleBySurface[surfaceKey] != title else { return false }
        lastTitleBySurface[surfaceKey] = title
        sequence &+= 1
        let wasEmpty = pendingUpdates.isEmpty && pendingRetirements.isEmpty
        pendingUpdates[surfaceKey] = GhosttyTitleUpdate(
            tabId: tabId,
            surfaceId: surfaceKey.surfaceId,
            title: title,
            sourceSurfaceIdentifier: surfaceKey.sourceSurfaceIdentifier,
            sequence: sequence
        )
        return wasEmpty
    }

    mutating func retire(_ surfaceKey: GhosttyTitleUpdateSurfaceKey) -> Bool {
        guard lastTitleBySurface.removeValue(forKey: surfaceKey) != nil else { return false }
        let wasEmpty = pendingUpdates.isEmpty && pendingRetirements.isEmpty
        pendingRetirements.insert(surfaceKey)
        pendingUpdates.removeValue(forKey: surfaceKey)
        return wasEmpty
    }

    mutating func takePendingOperations() -> [PendingOperation] {
        let keys = Set(pendingUpdates.keys).union(pendingRetirements)
        var operations: [PendingOperation] = []
        operations.reserveCapacity(keys.count)
        for key in keys {
            operations.append((
                retirement: pendingRetirements.contains(key) ? key : nil,
                update: pendingUpdates[key]
            ))
        }
        pendingUpdates.removeAll(keepingCapacity: true)
        pendingRetirements.removeAll(keepingCapacity: true)
        return operations
    }
}
