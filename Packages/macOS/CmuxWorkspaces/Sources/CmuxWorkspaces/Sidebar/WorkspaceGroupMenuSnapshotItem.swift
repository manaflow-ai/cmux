public import Foundation

/// One workspace group menu entry.
public struct WorkspaceGroupMenuSnapshotItem: Equatable, Identifiable, Sendable {
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
