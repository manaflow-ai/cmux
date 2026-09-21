internal import AppKit
internal import GhosttyKit
public import CmuxTerminalCore

extension TerminalSurface {
    /// Raw sizing sample for calibration diagnostics: `ghostty_surface_size`'s
    /// device-pixel fields UNCONVERTED, plus the attached view's bounds in
    /// points and its window's backing scale. Callers separate view layout,
    /// scale, padding, and cell quantization themselves — pre-mixed units are
    /// how sizing bugs hide (call sites have treated the raw pixel cell size
    /// as points in one place and as pixels in another).
    @MainActor
    public func rawSizingSample() -> TerminalSurfaceRawSizingSample? {
        guard let surface = liveSurfaceForGhosttyAccess(reason: "rawSizingSample") else { return nil }
        let size = ghostty_surface_size(surface)
        return TerminalSurfaceRawSizingSample(
            columns: Int(size.columns),
            rows: Int(size.rows),
            cellWidthPx: Int(size.cell_width_px),
            cellHeightPx: Int(size.cell_height_px),
            surfaceWidthPx: Int(size.width_px),
            surfaceHeightPx: Int(size.height_px),
            viewBoundsPt: attachedView?.bounds.size,
            backingScale: attachedView?.window?.backingScaleFactor
        )
    }
    /// Delivers the manual-size report that was skipped because the view was
    /// outside any window when the size applied (see
    /// ``manualSizeReportPendingWindowAttach``). Called from the attach path;
    /// a no-op unless a report is actually owed and deliverable.
    @MainActor
    public func flushPendingManualSizeReportIfAttached() {
        guard manualSizeReportPendingWindowAttach,
              let report = onManualSizeApplied,
              let realWindow = uiWindow,
              attachedView?.window === realWindow,
              let sample = rawSizingSample(),
              sample.columns > 1, sample.rows > 1
        else { return }
        manualSizeReportPendingWindowAttach = false
        let work = terminalWork.begin(.ptyResizeRequest, workspaceID: tabId)
        defer { work?.end() }
        report(sample)
    }
    /// Which of ``renderedGridCells()``'s nil conditions currently hold —
    /// lets sizing diagnostics name the mechanism (view detached from its
    /// window vs surface not live vs no real grid) instead of a bare nil.
    @MainActor
    public func renderedGridDiagnostics() -> (viewInWindow: Bool, surfaceLive: Bool) {
        (
            viewInWindow: attachedView?.window != nil,
            surfaceLive: liveSurfaceForGhosttyAccess(reason: "renderedGridDiagnostics") != nil
        )
    }
    /// The on-screen rendered grid, or nil while the runtime surface is not
    /// live, is not in a window, or has no real grid yet.
    @MainActor
    public func renderedGridCells() -> (columns: Int, rows: Int)? {
        guard attachedView?.window != nil,
              let surface = liveSurfaceForGhosttyAccess(reason: "renderedGridCells") else { return nil }
        let size = ghostty_surface_size(surface)
        let cols = Int(size.columns)
        let rows = Int(size.rows)
        guard cols > 1, rows > 1 else { return nil }
        return (cols, rows)
    }
}
