public import Foundation

/// Outcome of `surface.pip`.
public enum ControlSurfacePipResolution: Equatable, Sendable {
    /// The requested action changed or confirmed the surface's PiP state.
    case changed(surfaceID: UUID, isInPictureInPicture: Bool)
    /// No surface matched the explicit selector or current routing context.
    case surfaceNotFound
    /// The selected surface type is not eligible for PiP.
    case unsupportedSurfaceType
    /// A return action targeted a surface that is not currently in PiP.
    case notInPictureInPicture
    /// The app-side mutation path rejected the requested state change.
    case failed
}
