public import Foundation

/// The outcome of locating the source surface for `surface.move`, preserving the
/// legacy `v2SurfaceMove` distinction between an unavailable `AppDelegate` and a
/// missing surface.
///
/// The legacy body guarded `AppDelegate.shared` (returning `unavailable` /
/// "AppDelegate not available") before guarding the surface lookup (returning
/// `not_found` / "Surface not found"). The app witness preserves that split so
/// the coordinator can map each to the identical error.
public enum ControlSurfaceMoveSourceResolution: Sendable, Equatable {
    /// `AppDelegate.shared` was `nil` (legacy `unavailable` / "AppDelegate not
    /// available").
    case appUnavailable
    /// The surface or its source workspace did not resolve (legacy `not_found` /
    /// "Surface not found").
    case surfaceNotFound
    /// The source surface located; carries its snapshot.
    case located(ControlSurfaceMoveSourceSnapshot)
}
