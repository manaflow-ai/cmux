import Foundation

/// Immutable snapshot of the group list offered by a row's context menu.
struct WorkspaceGroupMenuSnapshot: Equatable {
    struct Item: Equatable, Identifiable {
        let id: UUID
        let name: String
    }

    let items: [Item]
}
