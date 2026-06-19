public import Foundation

/// Errors surfaced by ``KanbanBoardRepository``.
public enum KanbanBoardRepositoryError: Error, Equatable {
    /// The board file on disk exists but could not be decoded. The repository
    /// refuses to overwrite it so the user's data is not silently destroyed.
    case corruptedBoardFile(workspaceId: UUID)
}
