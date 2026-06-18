internal import Foundation

/// The outcome of the `surface.resume.set` / `.get` / `.clear` methods, preserving
/// the legacy bodies' distinct failures and the resume result they echo back.
///
/// The coordinator validates the routing params (returning `invalid_params` for a
/// present-but-invalid `window_id`/`workspace_id`/`surface_id`/`tab_id`) and the
/// required command for `resume.set` itself; the seam resolves the target, runs
/// the app-side approval flow, stores/reads/clears the binding, and returns this.
public enum ControlSurfaceResumeResolution: Sendable, Equatable {
    /// No TabManager / window resolved (legacy `unavailable` with the shared
    /// "cmux window is not available…" message).
    case windowUnavailable
    /// No surface target resolved (legacy `not_found` / "Surface not found").
    case surfaceNotFound
    /// `resume.set` rejected an empty resume command (legacy `invalid_params` /
    /// "Resume command is empty").
    case emptyResumeCommand
    /// `resume.set`'s store call failed for any other reason (legacy
    /// `internal_error` / "Failed to set resume binding").
    case setFailed
    /// The resume result. Carries the echoed identity, the cleared flag, and the
    /// resulting binding (a `null` binding still emits the `resume_binding` key).
    case result(ControlSurfaceResumeSnapshot)
}
