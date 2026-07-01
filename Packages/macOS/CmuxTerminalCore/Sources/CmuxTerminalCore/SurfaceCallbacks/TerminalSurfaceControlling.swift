public import Foundation
public import GhosttyKit

/// The surface-model side of the runtime callback seam.
///
/// Implemented by the app's terminal surface model (the owner of the
/// `ghostty_surface_t` lifecycle) so ``GhosttySurfaceCallbackContext`` can
/// identify the surface and reach its live runtime pointer without importing
/// the model layer.
public protocol TerminalSurfaceControlling: AnyObject {
    /// The stable identity of the terminal surface.
    var surfaceId: UUID { get }

    /// The workspace tab that owns the surface.
    var owningTabId: UUID { get }

    /// The live runtime surface pointer, or `nil` when the runtime surface
    /// does not currently exist.
    var runtimeSurfacePointer: ghostty_surface_t? { get }

    /// Whether the surface was configured to stay open after its startup
    /// command exits (`wait-after-command`). When `true` the host should
    /// decline to handle `SHOW_CHILD_EXITED` so Ghostty can display its
    /// built-in "Process exited. Press any key…" prompt.
    var waitAfterCommand: Bool { get }
}
