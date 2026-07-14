public import CMUXMobileCore

/// An immutable, renderer-ready terminal cell-grid preview for one surface.
public struct PreviewGridSnapshot: Equatable, Sendable {
    /// The terminal surface represented by the snapshot.
    public let surfaceID: String
    /// The producer sequence covered by the snapshot.
    public let stateSeq: UInt64
    /// Number of terminal columns in the source grid.
    public let columns: Int
    /// Number of terminal rows in the source grid.
    public let rows: Int
    /// The primary or alternate screen represented by the snapshot.
    public let activeScreen: MobileTerminalRenderGridFrame.Screen
    /// Renderer-ready rows containing explicitly positioned spans.
    public let lines: [PreviewGridLine]
    /// Whether an authoritative full frame has established this snapshot.
    public let hasBaseline: Bool

    /// Creates the skeleton state used before an authoritative full frame arrives.
    /// - Parameter surfaceID: The terminal surface awaiting a baseline.
    /// - Returns: An empty snapshot suitable for a placeholder renderer.
    public static func awaitingBaseline(surfaceID: String) -> PreviewGridSnapshot {
        PreviewGridSnapshot(
            surfaceID: surfaceID,
            stateSeq: 0,
            columns: 0,
            rows: 0,
            activeScreen: .primary,
            lines: [],
            hasBaseline: false
        )
    }
}
