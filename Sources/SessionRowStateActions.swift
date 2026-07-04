/// Read/toggle bundle for a row's persisted pin/archive state. Closure bundles
/// keep views below the snapshot boundary from holding `SessionIndexStore`.
struct SessionRowStateActions {
    let isPinned: @MainActor (SessionEntry.ID) -> Bool
    let isArchived: @MainActor (SessionEntry.ID) -> Bool
    let togglePinned: @MainActor (SessionEntry) -> Void
    let toggleArchived: @MainActor (SessionEntry) -> Void
}
