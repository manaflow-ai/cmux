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
    /// Evicted-terminal last frames this session showed while it attached (cx-8w027.10 b).
    public var lastFrameHolds: Int = 0
    /// A held frame (a last frame, or the old surface's after a swap) is on screen now.
    public var holdingFrame: Bool = false

    /// True when the surface can show terminal content right now.
    public var isPresentable: Bool {
        guard hasSurface, surfaceInHost, inWindow, !hidden, drawing == true else { return false }
        guard let grid, grid.columns > 0, grid.rows > 0 else { return false }
        return viewSize.width >= 1 && viewSize.height >= 1
    }
}

extension TerminalSession {
    /// The grid Ghostty's last frame drew (``TerminalSurfaceDiagnostics/drawnGrid``) and the owner's
    /// locked grid, without the rest of ``diagnostics``: cheap enough to read every display frame.
    public var drawnAndOwnerGrid: (drawn: TerminalGridSize?, owner: TerminalGridSize?) {
        guard let surface = surfaceView.surface else { return (nil, nil) }
        var columns: UInt16 = 0, rows: UInt16 = 0
        let drawn = ghostty_surface_drawn_grid(surface, &columns, &rows) ? TerminalGridSize(columns: Int(columns), rows: Int(rows)) : nil
        let grid = ghostty_surface_grid(surface)
        return (drawn, grid.locked ? TerminalGridSize(columns: Int(grid.columns), rows: Int(grid.rows)) : nil)
    }

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
                                              blendFrames: counters.blend_frames, frameUpdates: counters.frame_updates,
                                              fullPalette: counters.full_palette, fullConfig: counters.full_config,
                                              fullFont: counters.full_font, fullOther: counters.full_other,
                                              fullSwap: counters.full_swap, fullResize: counters.full_resize,
                                              hostDisplayPasses: counters.host_display_passes,
                                              hostPresentCalls: counters.host_present_calls,
                                              hostMainDraws: counters.host_main_draws,
                                              hostFreshPresents: counters.host_fresh_presents,
                                              hostLatePresents: counters.host_late_presents)
            },
            windowFraction: surface.window.flatMap { window in
                let frame = window.frame
                guard frame.width > 0, frame.height > 0 else { return nil }
                let rect = surface.convert(surface.bounds, to: nil)
                return CGRect(x: rect.minX / frame.width, y: 1 - rect.maxY / frame.height,
                              width: rect.width / frame.width, height: rect.height / frame.height)
            },
            lastFrameHolds: lastFrameHolds,
            holdingFrame: frameHold.isHolding
        )
    }
}

/// Ghostty's frame counters for one surface (``TerminalSurfaceDiagnostics/renderCounters``).
public struct TerminalRenderCounters: Sendable, Equatable {
    public var frames: UInt64
    /// Frame updates that rebuilt at least one row of cells.
    public var cellRebuilds: UInt64
    public var blendFrames: UInt64
    /// Frame updates, with or without rebuilt rows.
    public var frameUpdates: UInt64
    /// Rebuilds of every row by cause: the terminal's palette (OSC 4, a restore), a config change
    /// of what cells hold (not only colors), a new font grid, anything else (resize, clear).
    public var fullPalette: UInt64
    public var fullConfig: UInt64
    public var fullFont: UInt64
    public var fullOther: UInt64
    /// Rebuilds of every row because the drawn terminal changed (a snapshot restore, the reflow
    /// preview starting or ending) or its grid size changed.
    public var fullSwap: UInt64
    public var fullResize: UInt64
    /// Host-sized display passes of a new size (ghostty-integration-DESIGN.md G1): frames the main
    /// thread drew itself (the first frame), frames the renderer thread drew at the new size with
    /// reflowed text and the pass presented in its own commit, and passes that kept the last frame
    /// because the new one was not ready within 4 ms (it lands at the next pass).
    public var hostDisplayPasses: UInt64 = 0
    /// `ghostty_surface_present_host_frame` calls (``TerminalHostFramePresenter``, before each commit).
    public var hostPresentCalls: UInt64 = 0
    public var hostMainDraws: UInt64 = 0
    public var hostFreshPresents: UInt64 = 0
    public var hostLatePresents: UInt64 = 0

    /// Every counter by its `debug.surfaces` name.
    public var byName: [String: UInt64] {
        ["frames": frames, "cell_rebuilds": cellRebuilds, "blend_frames": blendFrames, "frame_updates": frameUpdates,
         "full_palette": fullPalette, "full_config": fullConfig, "full_font": fullFont, "full_other": fullOther,
         "full_swap": fullSwap, "full_resize": fullResize, "host_display_passes": hostDisplayPasses, "host_present_calls": hostPresentCalls, "host_main_draws": hostMainDraws,
         "host_fresh_presents": hostFreshPresents, "host_late_presents": hostLatePresents]
    }
}
