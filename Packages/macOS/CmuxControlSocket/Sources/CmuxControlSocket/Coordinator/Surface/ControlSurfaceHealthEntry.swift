public import Foundation

/// A read-only render-health row for one surface in the `surface.health` payload.
///
/// Mirrors the legacy per-surface dictionary the `v2SurfaceHealth` body built. The
/// `inWindow` value is optional: the app reports a Bool for render-backed panels
/// with inspectable host views and `NSNull` for panel kinds without a health
/// witness. The coordinator mints the surface ref and writes the index.
public struct ControlSurfaceHealthEntry: Sendable, Equatable {
    /// The surface's panel identifier.
    public let surfaceID: UUID
    /// The panel type's raw value.
    public let typeRawValue: String
    /// Whether the surface's hosting view is in a window: a Bool for terminal,
    /// browser, and Agent Session panels, `nil` (JSON `null`) for panel kinds
    /// without a health witness.
    public let inWindow: Bool?

    /// Creates a surface-health entry.
    ///
    /// - Parameters:
    ///   - surfaceID: The surface's panel identifier.
    ///   - typeRawValue: The panel type's raw value.
    ///   - inWindow: Whether the surface's hosting view is in a window, or `nil`
    ///     for panel kinds without a health witness.
    public init(
        surfaceID: UUID,
        typeRawValue: String,
        inWindow: Bool?
    ) {
        self.surfaceID = surfaceID
        self.typeRawValue = typeRawValue
        self.inWindow = inWindow
    }
}
