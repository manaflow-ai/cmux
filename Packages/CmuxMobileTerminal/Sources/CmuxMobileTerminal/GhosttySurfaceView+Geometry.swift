#if canImport(UIKit)
import CMUXMobileCore
import CmuxMobileDiagnostics
import CmuxMobileTerminalKit
import GhosttyKit
import OSLog
import UIKit

// MARK: - Geometry, Grid Sizing & Letterboxing
extension GhosttySurfaceView {
    #if DEBUG
    struct DebugGeometrySnapshot {
        let boundsSize: CGSize
        let renderRect: CGRect
        let screenScale: CGFloat
        let reportedSize: TerminalGridSize?
        let renderedSize: TerminalGridSize?
        let isLetterboxBorderVisible: Bool
        let letterboxBorderPathBounds: CGRect?
    }

    func debugGeometrySnapshotForTesting() -> DebugGeometrySnapshot {
        let renderedSize: TerminalGridSize? = {
            guard let surface else { return nil }
            let size = ghostty_surface_size(surface)
            return TerminalGridSize(
                columns: Int(size.columns),
                rows: Int(size.rows),
                pixelWidth: Int(size.width_px),
                pixelHeight: Int(size.height_px)
            )
        }()
        return DebugGeometrySnapshot(
            boundsSize: bounds.size,
            renderRect: lastRenderRect,
            screenScale: preferredScreenScale,
            reportedSize: lastReportedSize,
            renderedSize: renderedSize,
            isLetterboxBorderVisible: letterboxBorderLayer?.isHidden == false,
            letterboxBorderPathBounds: letterboxBorderLayer?.path?.boundingBoxOfPath
        )
    }

    func setKeyboardHeightForTesting(_ height: CGFloat) {
        keyboardHeight = max(0, height)
        syncSurfaceGeometry(shouldReassertNaturalSize: true)
    }
    #endif

    var currentGridSize: TerminalGridSize {
        lastReportedSize ?? TerminalGridSize(columns: 100, rows: 32, pixelWidth: 900, pixelHeight: 650)
    }

    /// Request a geometry recompute on the next display-link frame. Triggers
    /// must call this instead of `syncSurfaceGeometry` directly so rapid
    /// events coalesce into one apply per frame.
    func setNeedsGeometrySync(reassertNaturalSize: Bool = true) {
        needsGeometrySync = true
        if reassertNaturalSize { pendingGeometryReassert = true }
        needsDraw = true
        // A geometry sync (for any reason) satisfies a pending post-zoom resync.
        zoomSettleFrames = nil
        if displayLink == nil, window != nil {
            // No frame pump while detached/backgrounded; apply directly so the
            // surface still gets sized before the next render path resumes.
            needsGeometrySync = false
            let reassert = pendingGeometryReassert
            pendingGeometryReassert = false
            syncSurfaceGeometry(shouldReassertNaturalSize: reassert)
        }
    }

    func syncSurfaceVisibility() {
        guard let surface else { return }
        let visible = window != nil &&
            !isHidden &&
            alpha > 0.01 &&
            bounds.width > 0 &&
            bounds.height > 0
        MobileDebugLog.anchormux("surface.occlusion visible=\(visible) window=\(window != nil) hidden=\(isHidden) alpha=\(alpha)")
        ghostty_surface_set_occlusion(surface, visible)
        if visible {
            updateCursorOverlay()
        } else {
            cursorOverlayLayer?.isHidden = true
        }
    }

    /// Re-arm the debounced viewport report after a round-trip returned no
    /// effective grid, so a transient RPC drop does not leave the render pinned
    /// to a stale effective grid (the "stuck letterbox" freeze). Bounded and
    /// display-link driven (the existing settle machinery re-fires it); a
    /// confirmed `applyViewSize` resets the counter. No-op once the cap is hit.
    public func retryViewportReport() {
        guard viewportReportRetries < Self.maxViewportReportRetries,
              let pending = lastReportedSize, pending.columns > 0, pending.rows > 0 else { return }
        viewportReportRetries += 1
        MobileDebugLog.anchormux(
            "zoom.viewport.retry \(viewportReportRetries)/\(Self.maxViewportReportRetries) "
            + "grid=\(pending.columns)x\(pending.rows)"
        )
        pendingViewportReport = pending
        viewportReportSettleFrames = 0
    }

    public func applyViewSize(cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return }
        // A value came back from the Mac, so the round-trip recovered.
        viewportReportRetries = 0
        if effectiveGrid?.cols == cols && effectiveGrid?.rows == rows { return }
        MobileDebugLog.anchormux("zoom.applyViewSize eff=\(effectiveGrid.map { "\($0.cols)x\($0.rows)" } ?? "nil")->\(cols)x\(rows)")
        effectiveGrid = (cols, rows)
        // Mark dirty instead of recomputing synchronously. This breaks the
        // feedback loop (didResize → updateTerminalViewport RPC → applyViewSize
        // → syncSurfaceGeometry → didResize …) that, under fast zoom, drove a
        // storm of set_size calls + viewport RPCs. Geometry now settles once
        // per frame, and reassert=false avoids re-reporting the unchanged
        // natural grid back through the round trip.
        setNeedsGeometrySync(reassertNaturalSize: false)
    }

    /// Pure libghostty resize refinement; `nonisolated` so it runs on the
    /// off-main surface queue (it touches only the passed surface pointer).
    nonisolated private static func fitSurfaceToGrid(
        _ surface: ghostty_surface_t,
        cols: Int,
        rows: Int,
        cellPixelSize: CGSize
    ) -> (requestedW: UInt32, requestedH: UInt32, actual: ghostty_surface_size_s) {
        var requestedW = UInt32(max(1, Int((CGFloat(cols) * cellPixelSize.width).rounded(.down))))
        var requestedH = UInt32(max(1, Int((CGFloat(rows) * cellPixelSize.height).rounded(.down))))

        ghostty_surface_set_size(surface, requestedW, requestedH)
        var actual = ghostty_surface_size(surface)

        // Ghostty's grid calculation subtracts padding and floors partial cells,
        // so the reverse mapping has to be confirmed against Ghostty itself.
        // This keeps the iOS mirror on the exact daemon grid instead of
        // occasionally rendering one column short.
        var steps = 0
        // Bounded refinement: a few single-pixel nudges are enough to land on
        // the exact grid. A high cap let a fast-zoom storm run this loop tens
        // of thousands of times across frames and burn the main thread.
        while steps < 8,
              Int(actual.columns) < cols || Int(actual.rows) < rows {
            if Int(actual.columns) < cols {
                requestedW += 1
            }
            if Int(actual.rows) < rows {
                requestedH += 1
            }
            ghostty_surface_set_size(surface, requestedW, requestedH)
            actual = ghostty_surface_size(surface)
            steps += 1
        }

        return (requestedW, requestedH, actual)
    }

    /// Result of an off-main geometry pass, handed back to the main actor.
    private struct GeometryResult: Sendable {
        let cellPixelSize: CGSize
        let naturalSize: TerminalGridSize
        /// Pinned render size in points when letterboxed to an effective
        /// grid; nil means fill the container.
        let pinnedSize: CGSize?
    }

    func syncSurfaceGeometry(shouldReassertNaturalSize: Bool = true) {
        guard let surface else { return }

        // Capture all main-actor inputs as values, then do every libghostty
        // WRITE (set_content_scale / set_size / fit) and its readback on the
        // serial surface queue. These calls push to libghostty's renderer
        // mailbox with a blocking `.forever` push; on the main thread they
        // hang it until the scene-update watchdog (0x8BADF00D) kills the app.
        // The main thread only applies the UIKit result. This is the single
        // off-main surface owner: main never calls a blocking libghostty API.
        let scale = preferredScreenScale
        // Reserve the persistent toolbar plus the keyboard when it is up. The
        // toolbar sits flush at the bottom edge and is what keeps the bottom TUI
        // rows off the home indicator, so the grid does NOT also reserve the
        // bottom safe area (that left an empty strip below the toolbar). The
        // toolbar and keyboard never stack (the toolbar rides above the
        // keyboard), so the bottom occupancy is the toolbar plus the keyboard.
        let reservedBottom = reservedToolbarHeight + max(0, keyboardHeight)
        let bottomInset = min(reservedBottom, max(0, bounds.height - 1))
        let containerW = max(1, bounds.width)
        let containerH = max(1, bounds.height - bottomInset)
        let containerPxW = UInt32(max(1, Int((containerW * scale).rounded(.down))))
        let containerPxH = UInt32(max(1, Int((containerH * scale).rounded(.down))))
        let eff = effectiveGrid
        let pushContentScale = abs(lastAppliedContentScale - scale) > 0.001
        if pushContentScale { lastAppliedContentScale = scale }

        Self.outputQueue.async { [weak self] in
            if pushContentScale {
                ghostty_surface_set_content_scale(surface, scale, scale)
            }
            ghostty_surface_set_size(surface, containerPxW, containerPxH)
            let measured = ghostty_surface_size(surface)

            var cell = CGSize.zero
            if measured.columns > 0, measured.rows > 0, measured.width_px > 0, measured.height_px > 0 {
                cell = CGSize(
                    width: CGFloat(measured.width_px) / CGFloat(measured.columns),
                    height: CGFloat(measured.height_px) / CGFloat(measured.rows)
                )
            }

            var pinnedSize: CGSize?
            if let eff, eff.cols > 0, eff.rows > 0, cell.width > 0, cell.height > 0 {
                let fillsNaturalGrid = eff.cols >= Int(measured.columns) && eff.rows >= Int(measured.rows)
                let withinOneCell = (Int(measured.columns) - eff.cols) <= 1 && (Int(measured.rows) - eff.rows) <= 1
                let pinnedW = CGFloat(eff.cols) * cell.width / scale
                let pinnedH = CGFloat(eff.rows) * cell.height / scale
                if !fillsNaturalGrid, !withinOneCell, pinnedW + 0.5 < containerW || pinnedH + 0.5 < containerH {
                    let fitted = Self.fitSurfaceToGrid(surface, cols: eff.cols, rows: eff.rows, cellPixelSize: cell)
                    let aw = fitted.actual.width_px > 0 ? fitted.actual.width_px : fitted.requestedW
                    let ah = fitted.actual.height_px > 0 ? fitted.actual.height_px : fitted.requestedH
                    pinnedSize = CGSize(
                        width: min(CGFloat(aw) / scale, containerW),
                        height: min(CGFloat(ah) / scale, containerH)
                    )
                }
            }

            let natural = TerminalGridSize(
                columns: Int(measured.columns),
                rows: Int(measured.rows),
                pixelWidth: Int(measured.width_px),
                pixelHeight: Int(measured.height_px)
            )
            let result = GeometryResult(cellPixelSize: cell, naturalSize: natural, pinnedSize: pinnedSize)
            DispatchQueue.main.async {
                self?.applyGeometryResult(
                    result,
                    scale: scale,
                    containerW: containerW,
                    containerH: containerH,
                    shouldReassertNaturalSize: shouldReassertNaturalSize
                )
            }
        }
    }

    /// Apply an off-main geometry pass on the main actor: only UIKit layer /
    /// cursor / border work plus the resize report. No blocking libghostty
    /// calls happen here.
    private func applyGeometryResult(
        _ result: GeometryResult,
        scale: CGFloat,
        containerW: CGFloat,
        containerH: CGFloat,
        shouldReassertNaturalSize: Bool
    ) {
        if result.cellPixelSize.width > 0, result.cellPixelSize.height > 0 {
            cellPixelSize = result.cellPixelSize
        }
        // Size the render layer to the EXACT pixel size libghostty rendered
        // (grid-aligned: cols×cellW × rows×cellH), not the raw container. The
        // present path discards any surface whose size != layer.bounds×scale,
        // and ghostty floors the grid to whole cells, so a container-sized
        // layer is up to ~one cell larger than the surface and EVERY frame is
        // discarded (blank terminal). Using the measured surface size makes
        // them match so frames present. Pinned (letterboxed) sizes are already
        // derived from the fitted surface px. Left-align + top-anchor either
        // way; any leftover container space is the letterbox margin.
        let naturalRenderSize = CGSize(
            width: max(1, CGFloat(result.naturalSize.pixelWidth) / scale),
            height: max(1, CGFloat(result.naturalSize.pixelHeight) / scale)
        )
        let renderRect = result.pinnedSize.map { CGRect(origin: .zero, size: $0) }
            ?? CGRect(origin: .zero, size: naturalRenderSize)
        lastRenderRect = renderRect
        MobileDebugLog.anchormux(
            "geom container=\(Int(containerW))x\(Int(containerH)) scale=\(scale) "
            + "cellPx=\(Int(result.cellPixelSize.width))x\(Int(result.cellPixelSize.height)) "
            + "natural=\(result.naturalSize.columns)x\(result.naturalSize.rows) "
            + "eff=\(effectiveGrid.map { "\($0.cols)x\($0.rows)" } ?? "nil") "
            + "pinned=\(result.pinnedSize.map { "\(Int($0.width))x\(Int($0.height))" } ?? "nil") "
            + "renderRect=\(Int(renderRect.width))x\(Int(renderRect.height))"
        )
        syncRendererLayerFrame(scale: scale, renderRect: renderRect)
        updateLetterboxBorder(
            renderRect: renderRect,
            isLetterboxed: renderRect.width + 0.5 < containerW || renderRect.height + 0.5 < containerH
        )
        updateCursorOverlay()
        needsDraw = true
        // Keep drawing for several frames so a frame lands at the final settled
        // layer size after CoreAnimation commits the bounds change. libghostty
        // discards a present whose surface size != the live layer (avoids the
        // garbled mis-scaled frame), so we must re-draw at the stable size until
        // one passes; otherwise the terminal stays blank. Bounded to avoid a
        // perpetual main-queue present flood. The renderer presents a frame
        // behind (see display link).
        pendingRenderFrames = 6
        syncSnapshotFallback()

        let naturalSize = result.naturalSize
        let effectiveMatchesNatural = effectiveGrid.map { grid in
            grid.cols == naturalSize.columns && grid.rows == naturalSize.rows
        } ?? true
        let shouldReportNaturalSize = naturalSize != lastReportedSize ||
            (shouldReassertNaturalSize && !effectiveMatchesNatural)
        guard shouldReportNaturalSize, naturalSize.columns > 0, naturalSize.rows > 0 else { return }
        lastReportedSize = naturalSize
        // Debounce the actual report (a PTY resize on the Mac) until the grid
        // settles; the display link fires it once it stops changing.
        pendingViewportReport = naturalSize
        viewportReportSettleFrames = 0
    }

    private func syncRendererLayerFrame(scale: CGFloat, renderRect: CGRect) {
        // Resize the render layer WITHOUT CoreAnimation's implicit ~0.25s
        // bounds/position animation. While that animation runs, the layer's
        // presentation size differs from the size libghostty just rendered, and
        // the present path discards any frame whose surface size != the live
        // layer (see `applyGeometryResult`). So after a resize/zoom-settle every
        // draw — including the bounded post-settle burst (~0.1s) — lands
        // mid-animation and is dropped, leaving a blank/stale surface until the
        // next input forces a redraw after the animation finally settled (the
        // "blanked out, typing brought it back" symptom). Disabling implicit
        // actions makes the bounds change land in one step, so a single redraw
        // presents at the final size immediately. The host layer and letterbox
        // border already suppress implicit actions; this keeps the render
        // sublayer consistent.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.contentsScale = scale
        for sublayer in layer.sublayers ?? [] where isGhosttyRendererLayer(sublayer) {
            if sublayer.frame != renderRect {
                sublayer.frame = renderRect
            }
            if sublayer.bounds.size != renderRect.size {
                sublayer.bounds = CGRect(origin: .zero, size: renderRect.size)
            }
            sublayer.contentsScale = scale
        }
        CATransaction.commit()
    }

    /// Add / update a 1-pixel separator border around the pinned surface
    /// rect when the container is larger (this device is not the smallest
    /// attached to the shared PTY). Smallest-device layouts have
    /// `isLetterboxed == false` and the border layer is hidden. Uses a
    /// CAShapeLayer so the stroke doesn't intercept touches / key events.
    private func updateLetterboxBorder(renderRect: CGRect, isLetterboxed: Bool) {
        guard isLetterboxed else {
            letterboxBorderLayer?.isHidden = true
            return
        }
        let border: CAShapeLayer = {
            if let existing = letterboxBorderLayer { return existing }
            let b = CAShapeLayer()
            b.name = "cmux.letterboxBorder"
            b.fillColor = UIColor.clear.cgColor
            b.lineWidth = 1.0
            b.zPosition = 1000 // above the Ghostty renderer layer
            b.isHidden = false
            b.actions = [
                "bounds": NSNull(),
                "frame": NSNull(),
                "hidden": NSNull(),
                "opacity": NSNull(),
                "path": NSNull(),
                "position": NSNull(),
                "strokeColor": NSNull(),
            ]
            // Decorative only; let pointer / key events pass through.
            b.isGeometryFlipped = false
            layer.addSublayer(b)
            letterboxBorderLayer = b
            return b
        }()
        border.isHidden = false
        border.strokeColor = UIColor.separator.resolvedColor(with: traitCollection).cgColor
        border.contentsScale = layer.contentsScale
        if border.frame != layer.bounds {
            border.frame = layer.bounds
        }

        let scale = max(border.contentsScale, 1)
        let lineWidth = border.lineWidth
        let alignedRect = CGRect(
            x: floor(renderRect.minX * scale) / scale,
            y: floor(renderRect.minY * scale) / scale,
            width: ceil(renderRect.width * scale) / scale,
            height: ceil(renderRect.height * scale) / scale
        )
        let pathInset = max(lineWidth / 2, 0.5 / scale)
        let outline = alignedRect.insetBy(dx: pathInset, dy: pathInset)
        let path = UIBezierPath(rect: outline).cgPath
        if border.path != path {
            border.path = path
        }
    }

    func isGhosttyRendererLayer(_ layer: CALayer) -> Bool {
        String(describing: type(of: layer)) == "IOSurfaceLayer"
    }

    func logLayerTree(reason: String) {
        let hostLayer = layer
        let hostSummary = "\(type(of: hostLayer)) bounds=\(hostLayer.bounds.integral.debugDescription) frame=\(hostLayer.frame.integral.debugDescription) contentsScale=\(hostLayer.contentsScale)"
        let childSummaries = (hostLayer.sublayers ?? []).prefix(4).enumerated().map { index, sublayer in
            "\(index):\(type(of: sublayer)) bounds=\(sublayer.bounds.integral.debugDescription) frame=\(sublayer.frame.integral.debugDescription) hidden=\(sublayer.isHidden) contents=\(sublayer.contents != nil) scale=\(sublayer.contentsScale)"
        }.joined(separator: " | ")
        MobileDebugLog.anchormux("surface.layers reason=\(reason) host=\(hostSummary) children=[\(childSummaries)] fallbackHidden=\(snapshotFallbackView.isHidden) fallbackChars=\(snapshotFallbackView.text.count)")
    }

}

#endif
