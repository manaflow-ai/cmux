import Foundation

/// Errors thrown by collaboration session operations.
public enum CollaborationSessionError: Error, Equatable, Sendable {
    /// The requested document is not open in this local session.
    case documentNotOpen(String)
}
