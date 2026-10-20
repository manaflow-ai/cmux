public import Foundation

/// A read-only snapshot of one workspace's checklist, as the app target
/// exposes it to ``ControlCommandCoordinator`` through
/// ``ControlWorkspaceTodoContext``. Item state/origin cross the seam as raw
/// wire strings so the package does not depend on the app-side checklist
/// types.
public struct ControlWorkspaceTodoChecklistSnapshot: Sendable, Equatable {
    /// One checklist item row.
    public struct Item: Sendable, Equatable {
        /// The item's stable identifier.
        public let id: UUID
        /// The task text.
        public let text: String
        /// The state raw value (`pending`, `in-progress`, `completed`).
        public let state: String
        /// The origin raw value (`user`, `agent`).
        public let origin: String

        /// Creates an item row.
        public init(id: UUID, text: String, state: String, origin: String) {
            self.id = id
            self.text = text
            self.state = state
            self.origin = origin
        }
    }

    /// The resolved workspace's identifier.
    public let workspaceID: UUID
    /// The checklist items, in display order.
    public let items: [Item]
    /// How many items are completed.
    public let completedCount: Int
    /// The text of the first item that is not completed, if any.
    public let firstUncheckedText: String?

    /// Creates a checklist snapshot.
    public init(
        workspaceID: UUID,
        items: [Item],
        completedCount: Int,
        firstUncheckedText: String?
    ) {
        self.workspaceID = workspaceID
        self.items = items
        self.completedCount = completedCount
        self.firstUncheckedText = firstUncheckedText
    }
}
