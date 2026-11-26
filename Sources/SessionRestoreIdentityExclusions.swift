import Foundation

@MainActor
final class SessionRestoreIdentityExclusions {
    private var excludedStableIds: Set<UUID> = []
    private var previousExclusionStack: [Set<UUID>] = []

    func beginRestore(excluding ids: Set<UUID>) {
        previousExclusionStack.append(excludedStableIds)
        excludedStableIds = ids
    }

    func endRestore() {
        excludedStableIds = previousExclusionStack.popLast() ?? []
    }

    func shouldAdopt(_ id: UUID) -> Bool {
        !excludedStableIds.contains(id)
    }
}
