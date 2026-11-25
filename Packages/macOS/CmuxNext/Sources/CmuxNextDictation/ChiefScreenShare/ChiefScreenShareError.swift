/// Why ``ChiefScreenShare/look()`` saw nothing.
public enum ChiefScreenShareError: Error, Sendable, Equatable {
    /// Sharing is off.
    case notSharing
    /// The screen could not be read.
    case unreadable
}
