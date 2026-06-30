import Foundation

/// Ephemeral cursor and selection state for one collaboration peer.
public struct PresenceState: Codable, Equatable, Sendable {
    /// The peer that owns this presence state.
    public let peerID: String
    /// The peer's display name.
    public let displayName: String
    /// The peer's display color.
    public let color: String
    /// The active repository-relative file path.
    public let activeFile: String?
    /// The UTF-16 cursor offset used by AppKit text views.
    public let cursor: Int
    /// The UTF-16 selection range, if any.
    public let selection: Range<Int>?
    /// A peer-local monotonic sequence number for stale-presence rejection.
    public let sequence: Int

    /// Creates peer presence state.
    public init(
        peerID: String,
        displayName: String,
        color: String,
        activeFile: String?,
        cursor: Int,
        selection: Range<Int>?,
        sequence: Int
    ) {
        self.peerID = peerID
        self.displayName = displayName
        self.color = color
        self.activeFile = activeFile
        self.cursor = cursor
        self.selection = selection
        self.sequence = sequence
    }
}
