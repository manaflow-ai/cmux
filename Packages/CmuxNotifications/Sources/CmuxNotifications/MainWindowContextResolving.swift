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
}
