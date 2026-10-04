public import AppKit
public import CmuxNextDesign

/// A point-in-time view of one terminal surface's on-screen state, for the
/// App's `debug.surfaces` report and its blank-pane invariant.
public struct TerminalSurfaceDiagnostics: Sendable, Equatable {
    /// Ghostty created the surface (`ghostty_surface_new` succeeded).
    public var hasSurface: Bool
    /// The current surface received a replay or output.
    public var hasContent: Bool
    /// The App paused rendering (hidden tab, off-screen pane).
    public var renderingSuspended: Bool
    /// Last value passed to `ghostty_surface_set_occlusion` (true = drawing).
    public var drawing: Bool?
    /// Why the surface does not draw (``WindowDrawPolicy``); nil while it draws.
    public var pause: SurfacePause?
    /// Grid the surface renders now.
    public var grid: TerminalGridSize?
    /// The live surface view is installed in the session's host view.
    public var surfaceInHost: Bool
    /// The surface view is in a window.
    public var inWindow: Bool
    /// The surface view or an ancestor is hidden.
    public var hidden: Bool
    /// Surface view bounds in points.
    public var viewSize: CGSize
    /// Backing layer bounds in points (Ghostty's IOSurface layer).
    public var layerSize: CGSize
    /// READY snapshots restored in place on this session's surfaces.
    public var restoredSnapshots: Int
    /// Surfaces swapped in for a later VT replay (byte-replay attach only).
    public var swappedSurfaces: Int
    /// Local-history restores that did not match the owner's history.
    public var localHistoryMismatches: Int = 0

    /// True when the surface can show terminal content right now.
    public var isPresentable: Bool {
        guard hasSurface, surfaceInHost, inWindow, !hidden, drawing == true else { return false }
        guard let grid, grid.columns > 0, grid.rows > 0 else { return false }
        return viewSize.width >= 1 && viewSize.height >= 1
    }
}

extension TerminalSession {
    public var diagnostics: TerminalSurfaceDiagnostics {
        let surface = surfaceView
        return TerminalSurfaceDiagnostics(
            hasSurface: surface.surface != nil,
            hasContent: surfaceHasContent,
            renderingSuspended: isRenderingSuspended,
            drawing: surface.lastOcclusionVisible,
            pause: surface.pause,
            grid: surface.currentGrid,
            surfaceInHost: surface.superview === view,
            inWindow: surface.window != nil,
            hidden: surface.isHiddenOrHasHiddenAncestor,
            viewSize: surface.bounds.size,
            layerSize: surface.layer?.bounds.size ?? .zero,
            restoredSnapshots: restoredSnapshots,
            swappedSurfaces: swappedSurfaces,
            localHistoryMismatches: localHistoryMismatches
        )
    }
}
