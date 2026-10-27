import Foundation

/// Seams the session priority coordinator plugs into. Each stays `nil` until
/// the coordinator assigns it, so the rank and its wiring build and test
/// without it.
@MainActor
enum SessionPriorityCoordinatorHook {
    /// Called after a user-initiated workspace move was recorded into a window's
    /// rank. A move that left the order as it was also reports, so the rank
    /// may be unchanged.
    static var userDidReorder: ((TabManager) -> Void)?
    /// Called when a workspace's priority-relevant state changes, by workspace id.
    static var workspaceStateDidChange: ((UUID) -> Void)?
    /// Called when the user asks cmux to adjust a workspace's Claude effort
    /// automatically, by workspace id, even when the workspace was not marked
    /// manual: it also lifts a `/effort` or `/model` seen on one of its panes.
    static var adjustAutomaticallyRequested: ((UUID) -> Void)?
}
