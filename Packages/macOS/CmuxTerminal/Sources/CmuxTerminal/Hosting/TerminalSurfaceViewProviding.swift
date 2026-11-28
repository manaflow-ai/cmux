public import AppKit

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
    /// - Returns: The inner view and the container that wraps it.
    func makeSurfaceViews(
        initialFrame: NSRect
    ) -> (surfaceView: any TerminalSurfaceNativeViewing, paneHost: any TerminalSurfacePaneHosting)
}
