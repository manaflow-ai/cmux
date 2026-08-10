internal import GhosttyKit

/// Couples native process shutdown with the matching final surface free.
///
/// A runtime generation owns both operations as one value so a custom free
/// cannot accidentally invoke Ghostty's termination API on a foreign pointer.
struct TerminalSurfaceRuntimeNativeTeardown: Sendable {
    let beginSurfaceTeardown: @Sendable (ghostty_surface_t) -> Void
    let freeSurface: @Sendable (ghostty_surface_t) -> Void

    static let ghostty = TerminalSurfaceRuntimeNativeTeardown(
        beginSurfaceTeardown: { surface in
            ghostty_surface_request_process_termination(surface)
        },
        freeSurface: { surface in
            ghostty_surface_free(surface)
        }
    )
}
