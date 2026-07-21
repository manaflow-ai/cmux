import Foundation

/// An event emitted by the host WebSocket transport.
public enum WorkspaceShareEvent: Equatable, Sendable {
    /// A validated version-one server frame.
    case frame(WorkspaceShareWireFrame)
    /// The socket ended and must be reconnected or the share stopped.
    case disconnected(String)
}
