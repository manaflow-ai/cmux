/// Host-side display context for one surface in the "Copy Debug Logs"
/// visible-terminal snapshot.
///
/// The hosting view registers a provider returning this (or `nil` while the
/// surface is off-screen); the registry pairs it with the session's viewport
/// text so a bug report shows what the user saw.
public struct GhosttySurfaceSnapshotContext: Sendable {
    /// Human-readable grid description (e.g. `"80x24"`).
    public let gridDescription: String
    /// Current font size in points.
    public let fontSize: Int

    /// Creates a snapshot context.
    /// - Parameters:
    ///   - gridDescription: Human-readable grid description.
    ///   - fontSize: Current font size in points.
    public init(gridDescription: String, fontSize: Int) {
        self.gridDescription = gridDescription
        self.fontSize = fontSize
    }
}
