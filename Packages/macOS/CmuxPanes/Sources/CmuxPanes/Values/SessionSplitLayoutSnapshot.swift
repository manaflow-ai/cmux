import Foundation

/// Persisted split metadata and its two child layout snapshots.
public struct SessionSplitLayoutSnapshot: Codable, Equatable, Sendable {
    /// The axis dividing the two children.
    public var orientation: SessionSplitOrientation
    /// The saved fractional position of the divider.
    public var dividerPosition: Double
    /// The first child in spatial order.
    public var first: SessionWorkspaceLayoutSnapshot
    /// The second child in spatial order.
    public var second: SessionWorkspaceLayoutSnapshot

    /// Creates a split-node snapshot.
    public init(
        orientation: SessionSplitOrientation,
        dividerPosition: Double,
        first: SessionWorkspaceLayoutSnapshot,
        second: SessionWorkspaceLayoutSnapshot
    ) {
        self.orientation = orientation
        self.dividerPosition = dividerPosition
        self.first = first
        self.second = second
    }
}
