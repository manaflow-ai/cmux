/// Identifies which process owns terminal rendering for a native host view.
///
/// Embedded views vend Ghostty's Metal layer and render a local
/// `ghostty_surface_t`. External-compositor views are interaction-only AppKit
/// hosts; their pixels arrive through a separately-mounted compositor.
public enum TerminalSurfaceRenderOwnership: Sendable, Equatable {
    /// The local process owns the embedded Ghostty renderer.
    case embeddedGhostty

    /// An external compositor owns the rendered pixels.
    case externalCompositor
}
