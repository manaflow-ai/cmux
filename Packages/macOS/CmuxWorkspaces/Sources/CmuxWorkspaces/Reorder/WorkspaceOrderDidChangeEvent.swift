public import Foundation

/// Posted after a workspace reorder/group operation changes the sidebar order.
/// The owning window's SwiftUI sidebar uses it to scroll the selected
/// workspace back into view when that workspace was one of the moved ids.
///
/// Delivery stays `NotificationCenter` on purpose: the legacy post is consumed
/// synchronously by `ContentView`'s scroll request in the same MainActor turn,
/// and a stream hop would let later list mutations interleave before the scroll
/// is requested. This wrapper only replaces the stringly userInfo key with one
/// typed encode/decode pair; the wire shape (notification name, key string,
/// value type) is byte-identical to the legacy `WorkspaceOrderChangeNotificationKey`
/// post. This mirrors ``SidebarMultiSelectionDidHideEvent``.
public struct WorkspaceOrderDidChangeEvent: Sendable {
    /// The legacy notification name (`cmux.workspaceOrderDidChange`).
    public static let notificationName = Notification.Name("cmux.workspaceOrderDidChange")

    private static let movedWorkspaceIdsKey = "movedWorkspaceIds"

    /// The workspace ids that moved in this reorder.
    public let movedWorkspaceIds: [UUID]

    /// Creates an event for posting.
    public init(movedWorkspaceIds: [UUID]) {
        self.movedWorkspaceIds = movedWorkspaceIds
    }

    /// Decodes the event from a received notification; `nil` when the
    /// notification does not carry the moved-ids payload.
    public init?(_ notification: Notification) {
        guard notification.name == Self.notificationName,
              let moved = notification.userInfo?[Self.movedWorkspaceIdsKey] as? [UUID] else {
            return nil
        }
        self.movedWorkspaceIds = moved
    }

    /// The legacy userInfo payload (`movedWorkspaceIds` keyed exactly like the
    /// legacy post).
    public func userInfo() -> [AnyHashable: Any] {
        [Self.movedWorkspaceIdsKey: movedWorkspaceIds]
    }
}
