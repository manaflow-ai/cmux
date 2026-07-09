internal import Foundation

/// The outcome of the live terminal drop-overlay animation probe behind the
/// v1-only `terminal_drop_overlay_probe` command.
///
/// The seam (``ControlDebugContext/controlDebugTerminalDropOverlayProbe(useDeferredPath:)``)
/// performs only the irreducible AppKit/ghostty live read and reports its
/// result through this value; the coordinator
/// (``ControlCommandCoordinator/debugTerminalDropOverlayProbeV1(_:)``) owns the
/// `[deferred|direct]` token parsing and reconstructs the v1 response string
/// (including the `animated` flag derived from `after > before` and the
/// `%.1fx%.1f` bounds formatting) byte-identically to the legacy body.
public enum ControlDebugTerminalDropOverlayProbeResolution: Sendable, Equatable {
    /// The controller's `TabManager` was unavailable (the legacy
    /// `"ERROR: TabManager not available"` precondition).
    case tabManagerUnavailable

    /// No workspace was selected (the legacy `"ERROR: No selected workspace"`).
    case noWorkspace

    /// No terminal panel was available in the selected workspace (the legacy
    /// `"ERROR: No terminal panel available"`).
    case noPanel

    /// The probe ran; carries the overlay subview counts before/after the probe
    /// and the overlay bounds the legacy body formatted into the response.
    case probed(before: Int, after: Int, boundsWidth: Double, boundsHeight: Double)
}
