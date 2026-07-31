public import Foundation

/// A read-only render-health row for one surface in the `surface.health` payload.
///
/// Mirrors the legacy per-surface dictionary the `v2SurfaceHealth` body built. The
/// `inWindow` value is optional: terminal, browser, and application panels write
/// a Bool; unsupported panel types map `nil` to JSON `null`. The coordinator
/// mints the surface ref and writes the index.
public struct ControlSurfaceHealthEntry: Sendable, Equatable {
    /// The surface's panel identifier.
    public let surfaceID: UUID
    /// The panel type's raw value.
    public let typeRawValue: String
    /// Whether the surface's hosting view is in a window for terminal, browser,
    /// and application panels; `nil` (JSON `null`) for other panel types.
    public let inWindow: Bool?
    /// Application capture lifecycle, when this is an application surface.
    public let applicationCaptureState: String?
    /// Stable capture failure code, when capture initialization failed.
    public let applicationCaptureError: String?
    /// Captured native window identifier, when known.
    public let applicationWindowID: UInt32?
    /// Captured native process identifier, when known.
    public let applicationProcessID: Int32?

    /// Creates a surface-health entry.
    ///
    /// - Parameters:
    ///   - surfaceID: The surface's panel identifier.
    ///   - typeRawValue: The panel type's raw value.
    ///   - inWindow: Whether the surface's hosting view is in a window, or `nil`
    ///     for unsupported panel types.
    ///   - applicationCaptureState: Stable application capture lifecycle state.
    ///   - applicationCaptureError: Stable application capture failure code.
    ///   - applicationWindowID: Captured native window identifier.
    ///   - applicationProcessID: Captured native process identifier.
    public init(
        surfaceID: UUID,
        typeRawValue: String,
        inWindow: Bool?,
        applicationCaptureState: String? = nil,
        applicationCaptureError: String? = nil,
        applicationWindowID: UInt32? = nil,
        applicationProcessID: Int32? = nil
    ) {
        self.surfaceID = surfaceID
        self.typeRawValue = typeRawValue
        self.inWindow = inWindow
        self.applicationCaptureState = applicationCaptureState
        self.applicationCaptureError = applicationCaptureError
        self.applicationWindowID = applicationWindowID
        self.applicationProcessID = applicationProcessID
    }
}
