public import Foundation

/// The outcome of `surface.report_shell_state`, preserving the legacy body's two
/// payload shapes.
///
/// The coordinator validates the params (workspace required, surface-if-present
/// must parse, state must parse) and mints refs. The legacy body never fails after
/// validation: with an explicit surface it returns the `published` flag; without
/// one it schedules the async resolve+update and returns the pending payload.
public enum ControlSurfaceReportShellStateResolution: Sendable, Equatable {
    /// An explicit surface was given; the legacy `.ok` echoes the surface, the
    /// state, and the publish decision. Carries whether the activity was
    /// published.
    case explicit(surfaceID: UUID, published: Bool)
    /// No explicit surface; the legacy `.ok` echoes a `null` surface with
    /// `published: true, pending: true` (the resolve+update runs asynchronously).
    case pending
}
