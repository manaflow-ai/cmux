public import Foundation

/// A read-only snapshot of one surface (tab) within a pane, as the app target
/// exposes it to ``ControlCommandCoordinator`` for the `pane.surfaces` payload
/// row.
///
/// Mirrors the legacy per-surface dictionary the `v2PaneSurfaces` body built.
/// The surface id and type are optional, matching the legacy `v2OrNull` writes
/// (a tab whose panel id can't be resolved, or a panel with no type). The
/// coordinator turns each summary into one row, minting the surface ref itself.
public struct ControlPaneSurfaceSummary: Sendable, Equatable {
    /// The surface's panel identifier, if it resolved.
    public let surfaceID: UUID?
    /// The tab's title.
    public let title: String
    /// The panel type's raw value, if the panel resolved.
    public let typeRawValue: String?
    /// Whether this surface is the selected tab in its pane.
    public let isSelected: Bool

    /// Creates a pane-surface summary.
    ///
    /// - Parameters:
    ///   - surfaceID: The surface's panel identifier, if resolved.
    ///   - title: The tab's title.
    ///   - typeRawValue: The panel type's raw value, if resolved.
    ///   - isSelected: Whether this surface is selected.
    public init(
        surfaceID: UUID?,
        title: String,
        typeRawValue: String?,
        isSelected: Bool
    ) {
        self.surfaceID = surfaceID
        self.title = title
        self.typeRawValue = typeRawValue
        self.isSelected = isSelected
    }
}
