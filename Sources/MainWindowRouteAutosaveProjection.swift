import Foundation

/// Keeps expensive autosave fingerprints aligned with the bounded set emitted
/// by the previous snapshot. Newly available slots are filled in current
/// persistence order; lifecycle topology itself is revisioned by its owner.
struct MainWindowRouteAutosaveProjection: Equatable, Sendable {
    let orderedWindowIds: [UUID]
    let fingerprintWindowIds: [UUID]

    init(
        orderedWindowIds: [UUID],
        previouslyPersistedWindowIds: [UUID],
        maximumFingerprintWindows: Int
    ) {
        var seenWindowIds: Set<UUID> = []
        let uniqueOrderedWindowIds = orderedWindowIds.filter {
            seenWindowIds.insert($0).inserted
        }
        self.orderedWindowIds = uniqueOrderedWindowIds

        let limit = max(0, maximumFingerprintWindows)
        guard limit > 0 else {
            fingerprintWindowIds = []
            return
        }

        let previouslyPersisted = Set(previouslyPersistedWindowIds)
        var selected = uniqueOrderedWindowIds.filter {
            previouslyPersisted.contains($0)
        }
        if selected.count > limit {
            selected.removeLast(selected.count - limit)
        }

        var selectedWindowIds = Set(selected)
        for windowId in uniqueOrderedWindowIds {
            guard selected.count < limit else { break }
            guard selectedWindowIds.insert(windowId).inserted else { continue }
            selected.append(windowId)
        }
        fingerprintWindowIds = selected
    }
}
