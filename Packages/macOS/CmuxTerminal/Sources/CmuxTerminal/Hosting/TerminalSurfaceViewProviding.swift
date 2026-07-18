public import AppKit

/// Identifies which process owns terminal rendering for a native host view.
///
/// Embedded views vend Ghostty's Metal layer and render a local
/// `ghostty_surface_t`. External-compositor views are interaction-only AppKit
/// hosts; their pixels arrive through a separately-mounted compositor.
public enum TerminalSurfaceRenderOwnership: Sendable, Equatable {
    case embeddedGhostty
    case externalCompositor
}

/// Creates the native-view pair a ``TerminalSurface`` owns.
///
/// `TerminalSurface.init` historically constructed `GhosttyNSView` and
/// `GhosttySurfaceScrollView` directly; those types live above this package,
/// so the composition root injects this factory instead.
@MainActor
public protocol TerminalSurfaceViewProviding {
    /// Creates the inner terminal view and its pane container.
    ///
    /// - Parameter initialFrame: The non-zero bootstrap frame for the inner
    ///   view (the backing layer needs non-zero bounds before first layout).
    /// - Parameter renderOwnership: The process boundary that determines
    ///   whether this view may allocate an embedded renderer layer.
    /// - Returns: The inner view and the container that wraps it.
    func makeSurfaceViews(
        initialFrame: NSRect,
        renderOwnership: TerminalSurfaceRenderOwnership
    ) -> (surfaceView: any TerminalSurfaceNativeViewing, paneHost: any TerminalSurfacePaneHosting)
}
