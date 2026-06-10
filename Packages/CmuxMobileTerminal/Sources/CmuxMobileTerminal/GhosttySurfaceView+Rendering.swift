#if canImport(UIKit)
import CMUXMobileCore
import CmuxMobileDiagnostics
import CmuxMobileTerminalKit
import GhosttyKit
import OSLog
import UIKit

// MARK: - Rendering, Display Link & Cursor Overlay
extension GhosttySurfaceView {
    @objc func handleAppWillResignActive() {
        suspendRendering()
    }

    @objc func handleAppDidEnterBackground() {
        // Backstop: `willResignActive` already suspended, but guarantee the
        // surface is occluded before the GPU goes away.
        suspendRendering()
    }

    @objc func handleAppDidBecomeActive() {
        resumeRendering()
    }

    @objc func handleAppWillEnterForeground() {
        guard surface != nil, window != nil else { return }
        // The Mac drops this device's sticky viewport pin a few seconds after the
        // connection backgrounds, so on reconnect it reverts to its own (often
        // larger) size. `lastReportedSize` is unchanged, so nothing re-reports on
        // its own — clear it and force a geometry pass so the natural grid is
        // re-sent. The report is queued now and flushed once `didBecomeActive`
        // restarts the frame pump (which also reconnects the socket).
        lastReportedSize = nil
        setNeedsGeometrySync(reassertNaturalSize: true)
    }

    /// Pause the render loop while the app is inactive or backgrounded.
    ///
    /// Marks the surface occluded (so `render_now`'s `drawFrame` early-returns
    /// before reaching the synchronous GPU `waitUntilCompleted`), trips the
    /// dispatch gate, and stops the frame pump. Idempotent: called from both
    /// `willResignActive` and `didEnterBackground`.
    private func suspendRendering() {
        renderingSuspended = true
        stopDisplayLink()
        guard let surface else { return }
        ghostty_surface_set_occlusion(surface, false)  // false = occluded; drawFrame skips
        setFocus(false)
    }

    /// Resume the render loop once the app is active again.
    ///
    /// A `render_now` in flight at suspend either drained (the GPU was still
    /// available before background) or never dispatched, and its main-thread
    /// completion may have been deferred while the queue was suspended — so clear
    /// the in-flight flag to guarantee the first foreground frame can dispatch,
    /// re-mark the surface visible, and restart the frame pump. Idempotent.
    private func resumeRendering() {
        renderingSuspended = false
        renderInFlight = false
        needsAnotherRender = false
        guard let surface, window != nil else { return }
        ghostty_surface_set_occlusion(surface, true)  // true = visible
        setFocus(true)
        needsDraw = true
        startDisplayLink()
    }

    func startDisplayLink() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: DisplayLinkProxy(target: self), selector: #selector(DisplayLinkProxy.handleDisplayLink))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        displayLink = link
        cursorBlinkState.start(now: CACurrentMediaTime())
        needsDraw = true
        updateCursorOverlay()
    }

    func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
        cursorOverlayLayer?.isHidden = true
    }

    /// Reset cursor to visible and restart blink cycle (call on user input).
    func resetCursorBlink() {
        guard surface != nil else { return }
        cursorBlinkState.reset(now: CACurrentMediaTime())
        needsDraw = true
        updateCursorOverlay()
    }

    @objc func handleDisplayLinkFire() {
        guard let surface else { return }
        #if DEBUG
        // Main-thread liveness heartbeat + presented-surface state. Time-gated,
        // no behavior change. The `contents`/size fields let an IDLE blank be
        // classified without a fresh output/geometry event: contents=false ⇒
        // the IOSurface lost its frame and nothing re-triggered a draw (redraw
        // bug); contents=true while the screen looks blank ⇒ the render-grid
        // content itself is empty (sync/producer). `sinceOutput` ties a blank
        // to a render-grid stream gap or rules it out. CALayer reads only — no
        // libghostty call, so no futex/main-thread-wedge risk.
        let nowHeartbeat = CACurrentMediaTime()
        if nowHeartbeat - lastHeartbeatTime >= 2.0 {
            lastHeartbeatTime = nowHeartbeat
            let renderLayer = (layer.sublayers ?? []).first(where: { isGhosttyRendererLayer($0) })
            let renderSize = renderLayer?.bounds.size ?? .zero
            let sinceOutputMs = lastOutputAppliedTime > 0
                ? Int((nowHeartbeat - lastOutputAppliedTime) * 1000)
                : -1
            MobileDebugLog.anchormux(
                "tick.alive win=\(window != nil) renderInFlight=\(renderInFlight) "
                + "needsDraw=\(needsDraw) contents=\(renderLayer?.contents != nil) "
                + "surf=\(Int(renderSize.width))x\(Int(renderSize.height)) "
                + "sinceOutput=\(sinceOutputMs)ms"
            )
        }
        #endif
        // Apply at most one coalesced zoom per frame. This only changes the
        // font; the geometry resync is deferred until zoom settles.
        let appliedZoom = applyPendingFontSizeIfNeeded()
        // Post-zoom geometry resync: once no new zoom target has landed for a
        // few quiet frames, do ONE resize to re-pin the letterbox at the
        // settled font. This is the single geometry change per zoom gesture
        // instead of one per step (which thrashed the IOSurface and wedged the
        // render queue).
        if !appliedZoom, var frames = zoomSettleFrames {
            frames -= 1
            if frames <= 0 {
                zoomSettleFrames = nil
                setNeedsGeometrySync()
            } else {
                zoomSettleFrames = frames
            }
        }
        // Apply geometry at most once per frame. Every trigger (resize, zoom,
        // keyboard, effective-grid pin) only marks `needsGeometrySync`, so a
        // fast pinch can no longer drive a synchronous per-event storm of
        // set_size calls (the source of the jumbled grid + renderer overload).
        if needsGeometrySync {
            needsGeometrySync = false
            let reassert = pendingGeometryReassert
            pendingGeometryReassert = false
            syncSurfaceGeometry(shouldReassertNaturalSize: reassert)
        }
        let now = CACurrentMediaTime()
        let blinkChanged = cursorBlinkState.advance(now: now)
        // Draw on content/cursor changes, and for a short bounded burst after
        // any geometry change. iOS has no renderer-side vsync, so a frame is
        // only produced when we ask. The renderer draws at the layer size read
        // at draw time and presents a frame behind, so a single post-resize
        // draw can land while the layer is still mid-animation, leaving a
        // stale, wrong-size surface on screen (the blank / crushed-strip
        // garble). Requesting a few extra frames after the geometry settles
        // guarantees a draw at the final size. It is bounded (not a perpetual
        // loop) so it never floods the main queue with `setSurface` present
        // blocks, which made the app unresponsive.
        let geometrySettling = pendingRenderFrames > 0
        if geometrySettling { pendingRenderFrames -= 1 }
        if needsDraw || blinkChanged || geometrySettling {
            needsDraw = false
            requestRender()
            updateCursorOverlay()
        }

        // Report the settled natural grid to the Mac once it has stopped
        // changing. `applyGeometryResult` resets the counter on every grid
        // change, so this only fires after the attach/keyboard/zoom settle —
        // one PTY resize instead of one per intermediate size.
        //
        // While a zoom is still in progress (`zoomSettleFrames` armed = a zoom
        // landed within the last few frames) HOLD the report entirely. Each
        // zoom step changes the natural grid; reporting mid-zoom makes the Mac
        // resize the PTY over and over, so a full-screen TUI (a coding agent,
        // vim, etc.) redraws at constantly-changing sizes and garbles into the
        // "bad intermediate state". Zoom is a LOCAL font change; the shared
        // grid should renegotiate exactly once, after the user settles.
        if let pending = pendingViewportReport {
            if zoomSettleFrames != nil {
                viewportReportSettleFrames = 0
            } else {
                viewportReportSettleFrames += 1
                if viewportReportSettleFrames >= Self.viewportReportSettleThreshold {
                    pendingViewportReport = nil
                    viewportReportSettleFrames = 0
                    MobileDebugLog.anchormux("zoom.report grid=\(pending.columns)x\(pending.rows)")
                    delegate?.ghosttySurfaceView(self, didResize: pending)
                }
            }
        }

        // Flush coalesced scroll to the Mac at most once per frame.
        flushPendingScrollIfNeeded()

        // Fade the zoom HUD once interaction has been quiet. Uses real elapsed
        // time off the continuous display link (no timer / sleep).
        if zoomOverlayShown,
           CACurrentMediaTime() - zoomOverlayLastInteraction > Self.zoomOverlayVisibleDuration {
            fadeOutZoomOverlay()
        }
    }

    /// Drive a full render cycle via `ghostty_surface_render_now`, dispatched
    /// to the off-main surface queue.
    ///
    /// On iOS libghostty's renderer-thread event loop does not pump frames
    /// (it's a platform-display-driven embedder), so `ghostty_surface_refresh`
    /// — which only wakes that loop — never produces a frame: `updateFrame`
    /// doesn't run, the cell grid stays 0x0, and the surface renders blank
    /// (uninitialized buffer shows as garbled). `render_now` instead runs
    /// `applyPendingResizeIfNeeded` + drainMailbox + `updateFrame` + drawFrame
    /// directly on the calling thread, so the terminal grid is sized and the
    /// cells are rebuilt from real content. We run it on `outputQueue` so the
    /// GPU encode/swap-chain wait stays OFF the main thread (calling it on main
    /// is what tripped the scene-update watchdog under fast zoom). The present
    /// still hops to main inside libghostty (`setSurface`). The display link
    /// gates this on `needsDraw`/`pendingRenderFrames`, so it is not a
    /// per-frame loop that would flood the main queue with present blocks.
    private func requestRender() {
        // Never dispatch a render into the background: a backgrounded
        // `render_now` can stall acquiring a swap-chain frame slot from
        // libghostty, leaving the serial output queue undrained. The acquire is
        // now bounded in libghostty (so a foreground stall self-heals as a
        // skipped frame the display link re-drives), but we still gate on
        // suspension; `resumeRendering` clears it on the next active transition.
        guard !renderingSuspended, let surface, !isDismantled else { return }
        // Coalesce: never let more than one render_now sit on the serial queue.
        // (Called on main from the display link.)
        if renderInFlight {
            needsAnotherRender = true
            return
        }
        renderInFlight = true
        let enqueuedAt = CACurrentMediaTime()
        Self.outputQueue.async { [weak self] in
            // Queue LAG = how long this render waited behind other ops. If this
            // climbs into hundreds of ms the queue is backlogged (the freeze).
            let lagMs = (CACurrentMediaTime() - enqueuedAt) * 1000
            if lagMs > 150 { MobileDebugLog.anchormux("oq.render.LAG \(Int(lagMs))ms") }
            ghostty_surface_render_now(surface)
            DispatchQueue.main.async {
                guard let self else { return }
                self.renderInFlight = false
                guard !self.isDismantled else {
                    self.needsAnotherRender = false
                    return
                }
                if self.needsAnotherRender {
                    self.needsAnotherRender = false
                    self.requestRender()
                }
            }
        }
    }

    func updateCursorOverlay() {
        guard let surface,
              hostCursorVisible,
              window != nil,
              !isHidden,
              alpha > 0.01,
              !lastRenderRect.isEmpty,
              cellPixelSize.width > 0,
              cellPixelSize.height > 0 else {
            cursorOverlayLayer?.isHidden = true
            return
        }
        let overlay = ensureCursorOverlayLayer()
        var x: Double = 0
        var y: Double = 0
        var width: Double = 0
        var height: Double = 0
        ghostty_surface_ime_point(surface, &x, &y, &width, &height)

        let scale = max(preferredScreenScale, 1)
        overlay.contentsScale = scale
        let cellWidth = max(cellPixelSize.width / scale, 1)
        let cellHeight = max(CGFloat(height), cellPixelSize.height / scale, 1)
        let cursorWidth = max(1.0 / scale, min(CGFloat(1.5), cellWidth))
        let cursorX = lastRenderRect.minX + CGFloat(x) - (cellWidth / 2)
        let cursorY = lastRenderRect.minY + CGFloat(y) - cellHeight
        overlay.frame = CGRect(
            x: floor(cursorX),
            y: floor(cursorY),
            width: cursorWidth,
            height: ceil(cellHeight)
        )
        overlay.backgroundColor = cursorBlinkState.isVisible
            ? (configCursorColor ?? UIColor(red: 0xc0/255.0, green: 0xc1/255.0, blue: 0xb5/255.0, alpha: 1.0)).cgColor
            : (configBackgroundColor ?? backgroundColor ?? .black).cgColor
        overlay.isHidden = false
    }

    private func ensureCursorOverlayLayer() -> CALayer {
        if let cursorOverlayLayer {
            return cursorOverlayLayer
        }
        let layer = CALayer()
        layer.name = "cmux.cursorOverlay"
        layer.zPosition = 1001
        layer.actions = [
            "backgroundColor": NSNull(),
            "bounds": NSNull(),
            "frame": NSNull(),
            "position": NSNull(),
        ]
        self.layer.addSublayer(layer)
        cursorOverlayLayer = layer
        return layer
    }

    func drawForWakeup() {
        guard surface != nil, window != nil, !isDismantled else { return }
        // Don't call `ghostty_surface_refresh` here: that wakes the renderer
        // thread to present asynchronously (`setSurface` → `dispatch_async` to
        // main → size-guard discard), which both blanks frames and competes
        // with the display-link's main-thread present. Just flag dirty; the
        // next display-link tick runs `render_now` on main (which itself does
        // drainMailbox + updateFrame), keeping a single present owner on main.
        needsDraw = true
    }

}

#endif
