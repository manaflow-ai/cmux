public import AppKit
public import Foundation
public import GhosttyKit

// MARK: - Surface sizing and scale

extension TerminalSurface {
    /// Clears renderer-owned geometry state at the explicit runtime lifecycle
    /// boundary. The `surface` pointer setter is also used by nonisolated
    /// deinit, so it cannot touch these main-actor fields safely.
    @MainActor
    func resetManualGeometryStateForRuntimeTransition() {
        manualGeometrySnapshot = nil
        manualGeometryRequestSequence = 0
        manualGeometryAppliedSequence = 0
        isBootstrappingManualGeometry = false
    }

    /// Match upstream Ghostty AppKit sizing: framebuffer dimensions are derived
    /// from backing-space points and truncated (never rounded up).
    func pixelDimension(from value: CGFloat) -> UInt32 {
        guard value.isFinite else { return 0 }
        let floored = floor(max(0, value))
        if floored >= CGFloat(UInt32.max) {
            return UInt32.max
        }
        return UInt32(floored)
    }

    @MainActor
    func scaleFactors(for view: any TerminalSurfaceNativeViewing) -> (x: CGFloat, y: CGFloat, layer: CGFloat) {
        let scale = max(
            1.0,
            view.window?.backingScaleFactor
                ?? view.layer?.contentsScale
                ?? NSScreen.main?.backingScaleFactor
                ?? 1.0
        )
        return (scale, scale, scale)
    }

    func scaleApproximatelyEqual(_ lhs: CGFloat, _ rhs: CGFloat, epsilon: CGFloat = 0.0001) -> Bool {
        abs(lhs - rhs) <= epsilon
    }

    /// Returns whether a backing-pixel resize should be forwarded to Ghostty.
    ///
    /// Ghostty uses one surface-size API for both renderer pixels and PTY
    /// geometry. Pixel churn can arrive without a terminal grid change;
    /// coalescing those pixel-only updates avoids redundant PTY resizes (and
    /// their `SIGWINCH`s) while preserving ordinary layout and scale changes.
    /// Process-owned surfaces use this in steady state because a harmless
    /// renderer-pixel delta would otherwise notify a tmux client; manual-I/O
    /// mirrors opt in only during interactions so their geometry samples keep
    /// refining the feed-forward size calculation.
    ///
    /// - Parameter currentColumns: The current terminal grid column count.
    /// - Parameter currentRows: The current terminal grid row count.
    /// - Parameter currentWidthPx: The current raw surface width in pixels.
    /// - Parameter currentHeightPx: The current raw surface height in pixels.
    /// - Parameter currentCellWidthPx: The current terminal cell width in pixels.
    /// - Parameter currentCellHeightPx: The current terminal cell height in pixels.
    /// - Parameter targetWidthPx: The candidate surface width in pixels.
    /// - Parameter targetHeightPx: The candidate surface height in pixels.
    /// - Parameter coalescePixelOnlyResize: Whether same-grid pixel-only resizes should be skipped.
    /// - Parameter hasAppliedPixelSize: Whether a previous runtime pixel size has been applied.
    /// - Returns: `true` when Ghostty should receive the new pixel size.
    public static func shouldApplySurfacePixelSizeChange(
        currentColumns: UInt32,
        currentRows: UInt32,
        currentWidthPx: UInt32,
        currentHeightPx: UInt32,
        currentCellWidthPx: UInt32,
        currentCellHeightPx: UInt32,
        targetWidthPx: UInt32,
        targetHeightPx: UInt32,
        coalescePixelOnlyResize: Bool,
        hasAppliedPixelSize: Bool
    ) -> Bool {
        guard hasAppliedPixelSize else { return true }
        guard coalescePixelOnlyResize else { return true }
        guard currentColumns > 0,
              currentRows > 0,
              currentCellWidthPx > 0,
              currentCellHeightPx > 0 else {
            return true
        }

        let cellWidth = UInt64(currentCellWidthPx)
        let cellHeight = UInt64(currentCellHeightPx)
        let currentColumnCount = UInt64(currentColumns)
        let currentRowCount = UInt64(currentRows)
        func mayChangeGrid(
            currentCount: UInt64,
            currentPixels: UInt64,
            cellPixels: UInt64,
            targetPixels: UInt64
        ) -> Bool {
            let currentGridPixels = currentCount * cellPixels
            guard targetPixels >= currentGridPixels else { return true }

            let nextGridPixels = currentGridPixels + cellPixels
            let paddingLower = currentPixels >= nextGridPixels ? currentPixels - nextGridPixels + 1 : 0
            let paddingUpper = currentPixels > currentGridPixels ? currentPixels - currentGridPixels : 0
            let unchangedLower = targetPixels >= nextGridPixels ? targetPixels - nextGridPixels + 1 : 0
            let unchangedUpper = targetPixels - currentGridPixels
            // Coalesce only when every padding value compatible with the current grid stays same-grid.
            return unchangedLower > paddingLower || unchangedUpper < paddingUpper
        }

        return mayChangeGrid(
            currentCount: currentColumnCount,
            currentPixels: UInt64(currentWidthPx),
            cellPixels: cellWidth,
            targetPixels: UInt64(targetWidthPx)
        ) || mayChangeGrid(
            currentCount: currentRowCount,
            currentPixels: UInt64(currentHeightPx),
            cellPixels: cellHeight,
            targetPixels: UInt64(targetHeightPx)
        )
    }

    /// The pixel size that renders exactly an assigned grid: each axis is
    /// the assignment's cells at the current cell size plus the surface's
    /// own chrome, whether the view is shorter or longer. Pure so the
    /// arithmetic is testable without a runtime surface.
    static func assignedGridPinnedSize(
        width: UInt32,
        height: UInt32,
        assignedColumns: Int,
        assignedRows: Int,
        cellWidthPx: UInt32,
        cellHeightPx: UInt32,
        padWidthPx: UInt32,
        padHeightPx: UInt32
    ) -> (width: UInt32, height: UInt32) {
        guard cellWidthPx > 0, cellHeightPx > 0, assignedColumns > 0, assignedRows > 0 else {
            return (width, height)
        }
        return (
            UInt32(assignedColumns) * cellWidthPx + padWidthPx,
            UInt32(assignedRows) * cellHeightPx + padHeightPx
        )
    }

    /// Sets the tmux-assigned grid for a manual-IO mirror pane and
    /// re-applies the current size when the pin changes the applied grid.
    /// Returns whether the pin grew on either axis — cells granted after
    /// tmux already streamed their rows hold nothing until tmux repaints,
    /// so the caller owes a redraw kick when this returns true.
    @MainActor
    @discardableResult
    public func setAssignedGrid(columns: Int, rows: Int) -> Bool {
        let assigned = (columns: columns, rows: rows)
        if let existing = assignedGrid, existing == assigned { return false }
        let grew = assignedGrid.map { columns > $0.columns || rows > $0.rows } ?? true
        assignedGrid = assigned
        reapplyAssignedGrid()
        return grew
    }

    /// Clears the pin (the pane left the mirror tree); the next genuine
    /// resize re-derives the grid from the view alone.
    @MainActor
    public func clearAssignedGrid() {
        guard assignedGrid != nil else { return }
        assignedGrid = nil
        reapplyAssignedGrid()
    }

    /// Re-applies the current pin's pixel size to the surface. The mirror
    /// calls this when a pane's rendered grid falls behind an assignment the
    /// pin already holds — an unchanged ``setAssignedGrid`` is a no-op, so the
    /// surface needs an explicit nudge back onto the pinned grid.
    @MainActor
    public func reapplyAssignedGrid() {
        guard ioMode.usesManualIO, lastUncappedPixelWidth > 0, lastUncappedPixelHeight > 0,
              lastXScale > 0, lastYScale > 0 else { return }
        _ = updateSize(
            width: CGFloat(lastUncappedPixelWidth) / lastXScale,
            height: CGFloat(lastUncappedPixelHeight) / lastYScale,
            xScale: lastXScale,
            yScale: lastYScale,
            layerScale: lastXScale
        )
    }

    /// Queues one manual-surface geometry request behind all output and input.
    /// The native lane performs the read, mutation, and readback as one FIFO
    /// operation. Main-actor layout therefore never observes or mutates a
    /// partially applied Ghostty size.
    @MainActor
    @discardableResult
    func enqueueManualGeometryUpdate(
        surface: ghostty_surface_t,
        width: UInt32,
        height: UInt32,
        xScale: CGFloat,
        yScale: CGFloat,
        coalescePixelOnlyResize: Bool,
        suppressAssignedGridPin: Bool,
        caller: StaticString
    ) -> Bool {
        guard width > 0, height > 0 else { return false }

        let assignedGrid = suppressAssignedGridPin ? nil : self.assignedGrid
        let previous = manualGeometrySnapshot
        let scaleChanged = previous.map {
            !scaleApproximatelyEqual(xScale, CGFloat($0.xScale))
                || !scaleApproximatelyEqual(yScale, CGFloat($0.yScale))
        } ?? true
        let gridChanged: Bool = {
            guard let assignedGrid else {
                return previous == nil
                    || previous?.widthPixels != width
                    || previous?.heightPixels != height
            }
            return previous == nil
                || previous?.columns != assignedGrid.columns
                || previous?.rows != assignedGrid.rows
        }()

        // A same-grid pixel-only event can still be useful when the lane has
        // no sample yet. Once a sample exists, the lane itself applies the
        // coalescing policy using the native metrics it just read.
        guard previous == nil || scaleChanged || gridChanged else { return false }

        manualGeometryRequestSequence &+= 1
        let sequence = manualGeometryRequestSequence
        let request = TerminalSurfaceManualGeometryRequest(
            widthPixels: width,
            heightPixels: height,
            xScale: Double(max(1, xScale)),
            yScale: Double(max(1, yScale)),
            applyScale: scaleChanged,
            deferScaleOnIncrease: gridChanged
                && (xScale > CGFloat(previous?.xScale ?? 0)
                    || yScale > CGFloat(previous?.yScale ?? 0)),
            applySize: true,
            assignedGrid: assignedGrid.map {
                TerminalSurfaceManualGrid(columns: $0.columns, rows: $0.rows)
            },
            suppressReflow: manualIONoReflow,
            coalescePixelOnlyResize: coalescePixelOnlyResize,
            hasAppliedPixelSize: previous != nil,
            sequence: sequence,
            runtimeGeneration: runtimeSurfaceGeneration,
            caller: String(describing: caller)
        )
        return remoteOutputLane.enqueueGeometry(
            request,
            to: surface,
            completion: { [weak self] result in
                self?.applyManualGeometryResult(result)
            }
        )
    }

    /// Applies the copied result of a lane-owned geometry operation. A stale
    /// generation or sequence cannot overwrite a newer runtime's dimensions.
    @MainActor
    private func applyManualGeometryResult(_ result: TerminalSurfaceManualGeometryResult) {
        guard result.runtimeGeneration == runtimeSurfaceGeneration,
              surface != nil,
              result.sequence >= manualGeometryAppliedSequence else { return }
        manualGeometryAppliedSequence = result.sequence
        manualGeometrySnapshot = result.snapshot
        lastPixelWidth = result.snapshot.widthPixels
        lastPixelHeight = result.snapshot.heightPixels
        lastXScale = CGFloat(result.snapshot.xScale)
        lastYScale = CGFloat(result.snapshot.yScale)

        guard let report = onManualSizeApplied else { return }
        let sample = TerminalSurfaceRawSizingSample(
            columns: result.snapshot.columns,
            rows: result.snapshot.rows,
            cellWidthPx: Int(result.snapshot.cellWidthPixels),
            cellHeightPx: Int(result.snapshot.cellHeightPixels),
            surfaceWidthPx: Int(result.snapshot.widthPixels),
            surfaceHeightPx: Int(result.snapshot.heightPixels),
            viewBoundsPt: attachedView?.bounds.size,
            backingScale: attachedView?.window?.backingScaleFactor
        )
        guard sample.columns > 1, sample.rows > 1 else {
            manualSizeReportPendingWindowAttach = true
            return
        }
        if attachedView?.window != nil {
            manualSizeReportPendingWindowAttach = false
            report(sample)
        } else {
            manualSizeReportPendingWindowAttach = true
        }
    }

    /// Applies a new backing size/scale to the runtime surface.
    ///
    /// - Parameter width: The logical surface width in points.
    /// - Parameter height: The logical surface height in points.
    /// - Parameter xScale: The horizontal backing scale.
    /// - Parameter yScale: The vertical backing scale.
    /// - Parameter layerScale: The backing scale assigned to the hosting layer.
    /// - Parameter backingSize: The precomputed backing size in pixels, if available.
    /// - Parameter coalescePixelOnlyResize: Whether same-grid pixel-only resizes should be skipped.
    /// - Parameter suppressAssignedGridPin: Skip the tmux-assigned grid pin for this
    ///   resize and use the view-derived size. Set while an interactive resize is
    ///   active: the pin holds the surface at the pre-drag (larger) assignment across
    ///   the whole drag, and presenting that oversized grid before the deferred
    ///   reconcile clamps it paints past the shrinking pane onto siblings. The pin
    ///   re-establishes at rest (drag end and tmux's layout reply both size the pane).
    /// - Parameter caller: The originating size-reconciliation entry point for debug tracing.
    /// - Returns: Whether a runtime size or scale change was applied.
    @discardableResult
    @MainActor
    public func updateSize(
        width: CGFloat,
        height: CGFloat,
        xScale: CGFloat,
        yScale: CGFloat,
        layerScale: CGFloat,
        backingSize: CGSize? = nil,
        coalescePixelOnlyResize: Bool = false,
        suppressAssignedGridPin: Bool = false,
        caller: StaticString = #function
    ) -> Bool {
        guard let surface = liveSurfaceForGhosttyAccess(reason: "updateSize") else { return false }
        _ = layerScale

        let resolvedBackingWidth = backingSize?.width ?? (width * xScale)
        let resolvedBackingHeight = backingSize?.height ?? (height * yScale)
        let rawWpx = pixelDimension(from: resolvedBackingWidth)
        let rawHpx = pixelDimension(from: resolvedBackingHeight)
        lastUncappedPixelWidth = rawWpx
        lastUncappedPixelHeight = rawHpx
        let fittedSize = mobileViewportFittedSize(
            width: rawWpx,
            height: rawHpx,
            surface: surface,
            reason: "updateSize"
        )
        var wpx = fittedSize.width
        var hpx = fittedSize.height
        guard wpx > 0, hpx > 0 else { return false }

        if ioMode.usesManualIO {
            return enqueueManualGeometryUpdate(
                surface: surface,
                width: wpx,
                height: hpx,
                xScale: xScale,
                yScale: yScale,
                coalescePixelOnlyResize: coalescePixelOnlyResize,
                suppressAssignedGridPin: suppressAssignedGridPin,
                caller: caller
            )
        }

        let scaleChanged = !scaleApproximatelyEqual(xScale, lastXScale) || !scaleApproximatelyEqual(yScale, lastYScale)
        let sizeChanged = wpx != lastPixelWidth || hpx != lastPixelHeight

        #if DEBUG
        Self.sizeLog("updateSize-call surface=\(id.uuidString.prefix(8)) size=\(wpx)x\(hpx) prev=\(lastPixelWidth)x\(lastPixelHeight) changed=\((scaleChanged || sizeChanged) ? 1 : 0)")
        #endif

        if mobileViewportCellLimit != nil {
            updateMobileViewportBorder(
                appliedWidth: wpx,
                appliedHeight: hpx,
                baseWidth: rawWpx,
                baseHeight: rawHpx
            )
        }

        guard scaleChanged || sizeChanged || fittedSize.fontChanged else { return false }

        #if DEBUG
        if sizeChanged {
            let win = attachedView?.window != nil ? "1" : "0"
            Self.sizeLog("updateSize surface=\(id.uuidString.prefix(8)) size=\(wpx)x\(hpx) prev=\(lastPixelWidth)x\(lastPixelHeight) win=\(win)")
        }
        #endif

        var shouldApplySizeChange = false
        if sizeChanged {
            // Coalesce pixel-only resizes first: if the candidate pixel size
            // doesn't change the terminal grid, skip the resize entirely. This
            // must run before any DECAWM toggling below so a coalesced (skipped)
            // resize never leaves a manual-I/O pane with DECAWM disabled.
            let currentSize = ghostty_surface_size(surface)
            shouldApplySizeChange = Self.shouldApplySurfacePixelSizeChange(
                currentColumns: UInt32(currentSize.columns),
                currentRows: UInt32(currentSize.rows),
                currentWidthPx: currentSize.width_px,
                currentHeightPx: currentSize.height_px,
                currentCellWidthPx: currentSize.cell_width_px,
                currentCellHeightPx: currentSize.cell_height_px,
                targetWidthPx: wpx,
                targetHeightPx: hpx,
                coalescePixelOnlyResize: coalescePixelOnlyResize && !scaleChanged,
                hasAppliedPixelSize: lastPixelWidth > 0 && lastPixelHeight > 0
            )
            if !shouldApplySizeChange {
                #if DEBUG
                Self.sizeLog(
                    "updateSize-skip-pixel-only surface=\(id.uuidString.prefix(8)) " +
                    "size=\(wpx)x\(hpx) prev=\(lastPixelWidth)x\(lastPixelHeight) " +
                    "grid=\(currentSize.columns)x\(currentSize.rows) " +
                    "cell=\(currentSize.cell_width_px)x\(currentSize.cell_height_px)"
                )
                #endif
                if fittedSize.fontChanged {
                    ghostty_surface_refresh(surface)
                }
            }
        }

        if fittedSize.fontChanged && !sizeChanged {
            ghostty_surface_refresh(surface)
        }

        // Apply scale and size through the same ordering and no-reflow
        // transaction used by runtime creation. This keeps the initial frame
        // and every later AppKit resize under one invariant.
        _ = applySurfaceGeometry(
            surface,
            width: wpx,
            height: hpx,
            xScale: xScale,
            yScale: yScale,
            applySize: shouldApplySizeChange,
            deferScaleOnIncrease: sizeChanged,
            caller: caller
        )

        // Remote tmux display surfaces: report every APPLIED resize —
        // including same-grid re-applies, since a resize that lands on new
        // pixels without changing cols×rows still refines the measured
        // padding constants (surface_px − cols·cell_px). Window attachment is
        // deliberately the ONLY visibility gate: surfaces on unselected tabs
        // must still report, because a hidden mirror's one-time size claim
        // (see RemoteTmuxWindowMirror.updateClientSize) is triggered by its
        // surfaces' first applied resize — the LISTENER owns the policy of
        // what a hidden report may do.
        if ioMode.usesManualIO, !isBootstrappingManualGeometry, let report = onManualSizeApplied {
            if let attachedView, attachedView.window != nil {
                manualSizeReportPendingWindowAttach = false
                let applied = ghostty_surface_size(surface)
                let cols = Int(applied.columns)
                let rows = Int(applied.rows)
                if cols > 1, rows > 1 {
                    report(TerminalSurfaceRawSizingSample(
                        columns: cols, rows: rows,
                        cellWidthPx: Int(applied.cell_width_px),
                        cellHeightPx: Int(applied.cell_height_px),
                        surfaceWidthPx: Int(applied.width_px),
                        surfaceHeightPx: Int(applied.height_px),
                        viewBoundsPt: attachedView.bounds.size,
                        backingScale: attachedView.window?.backingScaleFactor
                    ))
                }
            } else {
                // Off-window apply (portal churn during attach, hidden tab
                // setup): remember that a report is owed. If the grid is
                // already final when the view enters a window, no further
                // apply will fire — the attach flush is the only delivery.
                manualSizeReportPendingWindowAttach = true
            }
        }

        // Let Ghostty continue rendering on its own wakeups for steady-state frames.
        return true
    }

    /// Applies one Ghostty scale/size transaction. Runtime creation and
    /// steady-state resizing must share this operation because Ghostty derives
    /// its cell grid from both values, and manual mirrors must keep DECAWM
    /// disabled across every size mutation.
    ///
    /// On an existing surface, an increasing backing scale is applied after
    /// the pixel size. Applying it first temporarily makes the cell larger
    /// than the old framebuffer and can truncate a mirrored screen before the
    /// authoritative source sends its redraw. A first runtime has no prior
    /// grid, so it applies scale first naturally.
    @MainActor
    @discardableResult
    func applySurfaceGeometry(
        _ surface: ghostty_surface_t,
        width: UInt32,
        height: UInt32,
        xScale: CGFloat,
        yScale: CGFloat,
        applySize: Bool,
        deferScaleOnIncrease: Bool,
        caller: StaticString
    ) -> (scaleChanged: Bool, sizeChanged: Bool) {
        let scaleChanged = !scaleApproximatelyEqual(xScale, lastXScale)
            || !scaleApproximatelyEqual(yScale, lastYScale)
        let sizeChanged = width != lastPixelWidth || height != lastPixelHeight
        let increase = xScale > lastXScale || yScale > lastYScale
        let deferScale = scaleChanged && deferScaleOnIncrease && increase && lastXScale > 0 && lastYScale > 0

        if scaleChanged && !deferScale {
            ghostty_surface_set_content_scale(surface, xScale, yScale)
            lastXScale = xScale
            lastYScale = yScale
        }

        if applySize, width > 0, height > 0 {
            let suppressManualReflow = ioMode.usesManualIO && manualIONoReflow
            if suppressManualReflow {
                writeProcessOutputData(Self.decawmDisableSequence, to: surface)
            }
            applySurfaceSize(surface, width: width, height: height, caller: caller)
            lastPixelWidth = width
            lastPixelHeight = height
            if ioMode.usesManualIO {
                // Async refresh, not render_now: render_now runs updateFrame on
                // the main thread and races the always-live macOS renderer
                // thread on a grid-size change.
                ghostty_surface_refresh(surface)
                if suppressManualReflow {
                    writeProcessOutputData(Self.decawmEnableSequence, to: surface)
                }
            }
        }

        if deferScale {
            ghostty_surface_set_content_scale(surface, xScale, yScale)
            lastXScale = xScale
            lastYScale = yScale
        }

        return (scaleChanged, sizeChanged)
    }

    /// The current monospace cell size in points, or nil if the runtime
    /// surface is not ready. Used by remote tmux mirror sizing.
    @MainActor
    public func cellSizePoints() -> CGSize? {
        if ioMode.usesManualIO, let snapshot = manualGeometrySnapshot,
           snapshot.cellWidthPixels > 0, snapshot.cellHeightPixels > 0 {
            let scale = max(snapshot.xScale, 1)
            return CGSize(
                width: Double(snapshot.cellWidthPixels) / scale,
                height: Double(snapshot.cellHeightPixels) / scale
            )
        }
        guard let surface = liveSurfaceForGhosttyAccess(reason: "cellSize") else { return nil }
        let size = ghostty_surface_size(surface)
        guard size.cell_width_px > 0, size.cell_height_px > 0 else { return nil }
        let scale = max(Double(lastXScale), 1)
        return CGSize(
            width: Double(size.cell_width_px) / scale,
            height: Double(size.cell_height_px) / scale
        )
    }

    /// Raw sizing sample for calibration diagnostics: `ghostty_surface_size`'s
    /// device-pixel fields UNCONVERTED, plus the attached view's bounds in
    /// points and its window's backing scale. Callers separate view layout,
    /// scale, padding, and cell quantization themselves — pre-mixed units are
    /// how sizing bugs hide (call sites have treated the raw pixel cell size
    /// as points in one place and as pixels in another).
    @MainActor
    public func rawSizingSample() -> TerminalSurfaceRawSizingSample? {
        if ioMode.usesManualIO, let snapshot = manualGeometrySnapshot {
            return TerminalSurfaceRawSizingSample(
                columns: snapshot.columns,
                rows: snapshot.rows,
                cellWidthPx: Int(snapshot.cellWidthPixels),
                cellHeightPx: Int(snapshot.cellHeightPixels),
                surfaceWidthPx: Int(snapshot.widthPixels),
                surfaceHeightPx: Int(snapshot.heightPixels),
                viewBoundsPt: attachedView?.bounds.size,
                backingScale: attachedView?.window?.backingScaleFactor
            )
        }
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
              attachedView?.window != nil,
              let sample = rawSizingSample(),
              sample.columns > 1, sample.rows > 1
        else { return }
        manualSizeReportPendingWindowAttach = false
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
        if ioMode.usesManualIO, let snapshot = manualGeometrySnapshot {
            guard snapshot.columns > 1, snapshot.rows > 1 else { return nil }
            return (snapshot.columns, snapshot.rows)
        }
        guard attachedView?.window != nil,
              let surface = liveSurfaceForGhosttyAccess(reason: "renderedGridCells") else { return nil }
        let size = ghostty_surface_size(surface)
        let cols = Int(size.columns)
        let rows = Int(size.rows)
        guard cols > 1, rows > 1 else { return nil }
        return (cols, rows)
    }

}
