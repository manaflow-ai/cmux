public import Foundation

/// Errors thrown by ``KanbanEngine`` when a request cannot be honored.
public enum KanbanEngineError: Error, Equatable {
    /// No card with the given id exists on the board.
    case unknownCard(UUID)
    /// Dispatch was refused because the board is already at its WIP limit
    /// (`building` + `testing` cards) and cannot admit another in-flight run.
    case wipLimitReached(limit: Int)
}
