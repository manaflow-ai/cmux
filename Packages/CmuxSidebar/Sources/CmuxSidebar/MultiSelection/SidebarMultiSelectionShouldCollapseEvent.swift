public import Foundation

/// Posted when keyboard-nav focuses a single workspace and the sidebar's
/// multi-selection state (a SwiftUI `@State` `Set<UUID>` separate from the
/// model) should collapse to that workspace.
///
/// Same delivery rationale as ``SidebarMultiSelectionDidHideEvent``: the
/// wire shape matches the legacy `SidebarMultiSelectionCollapseKey` post
/// byte-for-byte; only the stringly userInfo access is typed.
public struct SidebarMultiSelectionShouldCollapseEvent: Sendable {
    /// The legacy notification name (`cmux.sidebarMultiSelectionShouldCollapse`).
    public static let notificationName = Notification.Name("cmux.sidebarMultiSelectionShouldCollapse")

    private static let focusedWorkspaceIdKey = "focusedWorkspaceId"

    /// The workspace the selection should collapse to.
    public let focusedWorkspaceId: UUID

    /// Creates an event for posting.
    public init(focusedWorkspaceId: UUID) {
        self.focusedWorkspaceId = focusedWorkspaceId
    }

    /// Decodes the event from a received notification; `nil` when the
    /// notification does not carry the focused-workspace payload.
    public init?(_ notification: Notification) {
        guard notification.name == Self.notificationName,
              let focusedId = notification.userInfo?[Self.focusedWorkspaceIdKey] as? UUID else {
            return nil
        }
        self.focusedWorkspaceId = focusedId
    }

    /// The legacy userInfo payload.
    public func userInfo() -> [AnyHashable: Any] {
        [Self.focusedWorkspaceIdKey: focusedWorkspaceId]
    }
}
