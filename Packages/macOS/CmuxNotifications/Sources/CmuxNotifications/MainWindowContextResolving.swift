public import Foundation

/// Resolves registered main windows into opaque ``MainWindowTarget`` values for
/// the navigation coordinator, hiding the concrete `MainWindowContext`,
/// `TabManager`, and `NSWindow`.
///
/// `orderedTargetsForUnreadJump` reproduces the legacy ordering used by
/// `openLatestWorkspaceUnread`: the preferred registered context (resolved from
/// the key/main window) first, then the session-snapshot ordering, de-duplicated
/// by window id.
@MainActor
public protocol MainWindowContextResolving: AnyObject {
    /// Registered windows in unread-jump preference order, de-duplicated by id.
    /// Mirrors `[preferredRegisteredMainWindowContext] + sortedMainWindowContextsForSessionSnapshot`.
    var orderedTargetsForUnreadJump: [MainWindowTarget] { get }

    /// Workspace ids owned by the *active* tab manager, independent of the
    /// window-context registry. Reproduces the legacy `self.tabManager.tabs`
    /// fallback in `openLatestWorkspaceUnread`: during early startup / VM timing
    /// the registry can lag behind model initialization, so an unread workspace
    /// owned by the active tab manager must still be resolvable even when
    /// `orderedTargetsForUnreadJump` is empty.
    var activeWorkspaceIdsForUnreadJump: [UUID] { get }
}
