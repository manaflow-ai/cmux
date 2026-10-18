public import AppKit
public import CmuxNextDesign
import GhosttyNextKit

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
    /// Grid the view's size fits: `grid` lags it until the owner announces the view's report.
    public var fitGrid: TerminalGridSize? = nil
    /// Grid of the terminal Ghostty's last frame drew: the reflow preview
    /// (``fitGrid``) during a resize the owner has not announced yet, else ``grid``.
    public var drawnGrid: TerminalGridSize? = nil
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
    /// Local-history READYs that kept the surface's own reflowed history.
    public var localSnapshots: Int = 0
    /// Kitty images the owner left out of its image replays.
    public var skippedImages: Int = 0
    /// Ghostty's frame counters (`ghostty_surface_render_counters`): frames drawn, frame updates
    /// that rebuilt cells, and frames drawn while a theme color blend ran (those change only the
    /// color table the shaders read).
    public var renderCounters: TerminalRenderCounters? = nil
    /// The surface's rect in its window as fractions of the window frame, top-left origin
    /// (x, y, width, height): where a window recording shows this terminal.
    public var windowFraction: CGRect? = nil

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
            fitGrid: surface.surface.map { surface in
                let size = ghostty_surface_size(surface)
                return TerminalGridSize(columns: Int(size.columns), rows: Int(size.rows))
            },
            drawnGrid: surface.surface.flatMap { surface in
                var columns: UInt16 = 0, rows: UInt16 = 0
                guard ghostty_surface_drawn_grid(surface, &columns, &rows) else { return nil }
                return TerminalGridSize(columns: Int(columns), rows: Int(rows))
            },
            surfaceInHost: surface.superview === view,
            inWindow: surface.window != nil,
            hidden: surface.isHiddenOrHasHiddenAncestor,
            viewSize: surface.bounds.size,
            layerSize: surface.layer?.bounds.size ?? .zero,
            restoredSnapshots: restoredSnapshots,
            swappedSurfaces: swappedSurfaces,
            localHistoryMismatches: localHistoryMismatches,
            localSnapshots: localSnapshots,
            skippedImages: skippedImages,
            renderCounters: surface.surface.map { surface in
                let counters = ghostty_surface_render_counters(surface)
                return TerminalRenderCounters(frames: counters.frames, cellRebuilds: counters.cell_rebuilds,
                                              blendFrames: counters.blend_frames)
            },
            windowFraction: surface.window.flatMap { window in
                let frame = window.frame
                guard frame.width > 0, frame.height > 0 else { return nil }
                let rect = surface.convert(surface.bounds, to: nil)
                return CGRect(x: rect.minX / frame.width, y: 1 - rect.maxY / frame.height,
                              width: rect.width / frame.width, height: rect.height / frame.height)
            }
        )
    }
}

/// Ghostty's frame counters for one surface (``TerminalSurfaceDiagnostics/renderCounters``).
public struct TerminalRenderCounters: Sendable, Equatable {
    public var frames: UInt64
    public var cellRebuilds: UInt64
    public var blendFrames: UInt64
}
