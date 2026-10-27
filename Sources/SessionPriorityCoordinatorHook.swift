import Foundation

/// Seams the session priority coordinator plugs into. Both stay `nil` until
/// the coordinator assigns them, so the rank and its wiring build and test
/// without it.
@MainActor
enum SessionPriorityCoordinatorHook {
    /// Called after a user-initiated workspace move recorded into a window's rank.
    static var userDidReorder: ((TabManager) -> Void)?
    /// Called when a workspace's priority-relevant state changes, by workspace id.
    static var workspaceStateDidChange: ((UUID) -> Void)?
}
