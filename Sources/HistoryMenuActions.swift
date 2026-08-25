import Foundation

/// Side-effecting History-menu actions supplied by the app composition root.
struct HistoryMenuActions {
    let reopenMostRecentlyClosedWorkspace: @MainActor (TabManager) -> Bool
    let reopenMostRecentlyClosedItem: @MainActor (TabManager) -> Bool
    let reopenClosedHistoryItem: @MainActor (UUID, TabManager) -> Bool
    let reopenPreviousSession: @MainActor () -> Bool

    /// No-op actions for projection-only tests.
    static let unavailable = HistoryMenuActions(
        reopenMostRecentlyClosedWorkspace: { _ in false },
        reopenMostRecentlyClosedItem: { _ in false },
        reopenClosedHistoryItem: { _, _ in false },
        reopenPreviousSession: { false }
    )
}
