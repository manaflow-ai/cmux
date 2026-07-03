public import Foundation

/// Immutable snapshot of the group list offered by a row's context menu.
public struct WorkspaceGroupMenuSnapshot: Equatable, Sendable {
    /// One workspace group menu entry.
    public struct Item: Equatable, Identifiable, Sendable {
        /// The workspace group's stable identifier.
        public let id: UUID
        /// The workspace group's current display name.
        public let name: String

        /// Creates a menu item for a workspace group.
        /// - Parameters:
        ///   - id: The workspace group's stable identifier.
        ///   - name: The workspace group's current display name.
        public init(id: UUID, name: String) {
            self.id = id
            self.name = name
        }
    }

    /// The workspace groups in menu order.
    public let items: [Item]

    /// Creates a group menu snapshot.
    /// - Parameter items: The workspace groups in menu order.
    public init(items: [Item]) {
        self.items = items
    }
}
