public import Foundation

/// Posted when specific workspaces become hidden (group collapse, group
/// creation). The SwiftUI sidebar should drop only those ids from its
/// multi-selection without disturbing other entries; when focus moved, the
/// focused row stays in the selection set.
///
/// Delivery stays `NotificationCenter` on purpose: the legacy posts are
/// consumed synchronously by the sidebar's SwiftUI `@State` selection in the
/// same MainActor turn, and a stream hop would let user mutations interleave
/// before the selection collapses. This wrapper only replaces the stringly
/// userInfo keys with one typed encode/decode pair; the wire shape
/// (notification name, key strings, value types) is byte-identical to the
/// legacy `SidebarMultiSelectionHideKey` post.
public struct SidebarMultiSelectionDidHideEvent: Sendable {
    /// The legacy notification name (`cmux.sidebarMultiSelectionDidHide`).
    public static let notificationName = Notification.Name("cmux.sidebarMultiSelectionDidHide")

    private static let hiddenWorkspaceIdsKey = "hiddenWorkspaceIds"
    private static let focusedWorkspaceIdKey = "focusedWorkspaceId"

    /// Workspace ids that just became hidden.
    public let hiddenWorkspaceIds: Set<UUID>
    /// The workspace focus moved to, when it moved.
    public let focusedWorkspaceId: UUID?

    /// Creates an event for posting.
    public init(hiddenWorkspaceIds: Set<UUID>, focusedWorkspaceId: UUID?) {
        self.hiddenWorkspaceIds = hiddenWorkspaceIds
        self.focusedWorkspaceId = focusedWorkspaceId
    }

    /// Decodes the event from a received notification; `nil` when the
    /// notification does not carry the hidden-ids payload.
    public init?(_ notification: Notification) {
        guard notification.name == Self.notificationName,
              let hidden = notification.userInfo?[Self.hiddenWorkspaceIdsKey] as? Set<UUID> else {
            return nil
        }
        self.hiddenWorkspaceIds = hidden
        self.focusedWorkspaceId = notification.userInfo?[Self.focusedWorkspaceIdKey] as? UUID
    }

    /// The legacy userInfo payload (`focusedWorkspaceId` present only when
    /// focus moved, exactly like the legacy posts).
    public func userInfo() -> [AnyHashable: Any] {
        var userInfo: [AnyHashable: Any] = [Self.hiddenWorkspaceIdsKey: hiddenWorkspaceIds]
        if let focusedWorkspaceId {
            userInfo[Self.focusedWorkspaceIdKey] = focusedWorkspaceId
        }
        return userInfo
    }
}
