public import Foundation

/// Immutable snapshot of the group list offered by a row's "Move to Group"
/// context-menu submenu. Computed once per parent body eval and passed into each
/// ``TabItemView`` so the row's `==` covers group changes (renames, adds,
/// deletes); the snapshot-boundary rule forbids the row reading the live group
/// store from inside the context-menu builder.
public struct WorkspaceGroupMenuSnapshot: Equatable {
    public struct Item: Equatable, Identifiable {
        public let id: UUID
        public let name: String

        public init(id: UUID, name: String) {
            self.id = id
            self.name = name
        }
    }

    public let items: [Item]

    public init(items: [Item]) {
        self.items = items
    }
}
