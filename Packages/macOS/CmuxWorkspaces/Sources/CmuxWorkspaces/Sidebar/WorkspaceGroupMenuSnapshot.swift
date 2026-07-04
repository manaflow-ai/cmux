public import Foundation

/// Immutable snapshot of the group list offered by a row's context menu.
public struct WorkspaceGroupMenuSnapshot: Equatable, Sendable {
    /// The workspace groups in menu order.
    public let items: [WorkspaceGroupMenuSnapshotItem]

    /// Creates a group menu snapshot.
    /// - Parameter items: The workspace groups in menu order.
    public init(items: [WorkspaceGroupMenuSnapshotItem]) {
        self.items = items
    }
}
