public import Foundation

/// A read-only render-health row for one surface in the `surface.health` payload.
///
/// Mirrors the legacy per-surface dictionary the `v2SurfaceHealth` body built. The
/// `inWindow` value is optional: the legacy body wrote a Bool for terminal/browser
/// panels and `NSNull` for any other panel type, so `nil` here maps to the same
/// JSON `null`. The coordinator mints the surface ref and writes the index.
public struct ControlSurfaceHealthEntry: Sendable, Equatable {
    /// The surface's panel identifier.
    public let surfaceID: UUID
    /// The panel type's raw value.
    public let typeRawValue: String
    /// Whether the surface's hosting view is in a window: a Bool for terminal
    /// (`isViewInWindow`) and browser (`webView.window != nil`) panels, `nil`
    /// (JSON `null`) for any other panel type.
    public let inWindow: Bool?

    /// Creates a surface-health entry.
    ///
    /// - Parameters:
    ///   - surfaceID: The surface's panel identifier.
    ///   - typeRawValue: The panel type's raw value.
    ///   - inWindow: Whether the surface's hosting view is in a window, or `nil`
    ///     for non-terminal/browser panels.
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
