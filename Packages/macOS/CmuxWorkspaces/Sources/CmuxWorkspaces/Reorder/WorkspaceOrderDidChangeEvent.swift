public import Foundation

/// Posted when one or more workspaces change position in the sidebar order
/// (drag reorder, group move, batch reorder), carrying the ids that moved.
///
/// Same delivery rationale as ``SidebarMultiSelectionShouldCollapseEvent``: the
/// wire shape matches the legacy `cmux.workspaceOrderDidChange` post
/// byte-for-byte (the `Notification.Name` stays app-side as transport, the
/// poster's `object` is still the posting `TabManager`); only the stringly
/// `userInfo[WorkspaceOrderChangeNotificationKey.movedWorkspaceIds]` access is
/// typed. The sole consumer reads `movedWorkspaceIds` to decide whether the
/// selected workspace scrolled into view.
public struct WorkspaceOrderDidChangeEvent: Sendable {
    /// The legacy notification name (`cmux.workspaceOrderDidChange`).
    public static let notificationName = Notification.Name("cmux.workspaceOrderDidChange")

    private static let movedWorkspaceIdsKey = "movedWorkspaceIds"

    /// The workspace ids that changed position in this reorder.
    public let movedWorkspaceIds: [UUID]

    /// Creates an event for posting.
    public init(movedWorkspaceIds: [UUID]) {
        self.movedWorkspaceIds = movedWorkspaceIds
    }

    /// Decodes the event from a received notification; `nil` when the
    /// notification does not carry the moved-workspace payload.
    public init?(_ notification: Notification) {
        guard notification.name == Self.notificationName,
              let movedWorkspaceIds = notification.userInfo?[Self.movedWorkspaceIdsKey] as? [UUID] else {
            return nil
        }
        self.movedWorkspaceIds = movedWorkspaceIds
    }

    /// The legacy userInfo payload.
    public func userInfo() -> [AnyHashable: Any] {
        [Self.movedWorkspaceIdsKey: movedWorkspaceIds]
    }
}
