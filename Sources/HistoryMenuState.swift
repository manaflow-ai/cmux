import CmuxWorkspaces

/// The main History menu's immutable render state for one active manager.
struct HistoryMenuState: Equatable {
    let managerIdentity: ObjectIdentifier?
    let recentlyFocusedItems: [FocusHistoryMenuItem]
    let recentlyClosed: ClosedItemHistoryMenuSnapshot
    let canNavigateBack: Bool
    let canNavigateForward: Bool

    static let empty = HistoryMenuState(
        managerIdentity: nil,
        recentlyFocusedItems: [],
        recentlyClosed: ClosedItemHistoryMenuSnapshot(items: [], totalItemCount: 0, isLimited: false),
        canNavigateBack: false,
        canNavigateForward: false
    )
}
