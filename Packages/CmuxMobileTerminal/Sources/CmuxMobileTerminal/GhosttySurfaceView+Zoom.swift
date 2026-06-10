#if canImport(UIKit)
import CMUXMobileCore
import CmuxMobileDiagnostics
import CmuxMobileTerminalKit
import GhosttyKit
import OSLog
import UIKit

// MARK: - Font Zoom & Zoom Overlay
extension GhosttySurfaceView {
    @discardableResult
    func performFontZoom(_ direction: TerminalFontZoomDirection) -> Bool {
        // Coalesce zoom: each tap only updates `pendingFontSize`; the display
        // link applies the LATEST target once per frame via an absolute
        // `set_font_size` (see `applyPendingFontSizeIfNeeded`). A burst of taps
        // therefore becomes one libghostty push + one resize per frame instead
        // of one per tap.
        //
        // Why this matters: every libghostty surface op on iOS runs on the
        // serial `outputQueue`, and they all BLOCK — the font push is a
        // `.forever` mailbox push, and the render that drains it waits on a
        // free GPU frame. Dispatching one blocking push per tap let the queue
        // accumulate pushes faster than the per-frame render drained them, so
        // the queue wedged and zoom froze. Coalescing caps the work at one
        // push per frame, which the render keeps pace with.
        //
        // Base the next step on `pendingFontSize` when a target is already
        // queued, so taps within the same frame still accumulate correctly.
        let delta: Float32 = direction == .increase ? 1 : -1
        let base = pendingFontSize ?? liveFontSize
        let target = base + delta
        guard target >= MobileTerminalFontPreference.minimumSize,
              target <= MobileTerminalFontPreference.maximumSize else {
            MobileDebugLog.anchormux("zoom.clamp dir=\(direction) base=\(base) target=\(target) range=[\(MobileTerminalFontPreference.minimumSize),\(MobileTerminalFontPreference.maximumSize)]")
            return false
        }
        guard surface != nil else { return false }

        pendingFontSize = target
        MobileDebugLog.anchormux("zoom.queue dir=\(direction) \(base)->\(target) live=\(liveFontSize)")
        scheduleDisplayLinkWork()
        showZoomOverlay()
        return true
    }

    /// Ensure a queued zoom (`pendingFontSize`) actually gets applied. While the
    /// display link runs, `handleDisplayLinkFire` picks the target up on the
    /// next frame. If the link is stopped (detached / backgrounded) nothing
    /// would pump it, so apply immediately.
    private func scheduleDisplayLinkWork() {
        needsDraw = true
        if displayLink == nil {
            applyPendingFontSizeIfNeeded()
        }
    }

    /// Apply the latest queued zoom target, called once per display-link frame.
    /// Pushes an absolute `set_font_size` off the main thread and renders the
    /// new font WITHOUT resizing the surface — geometry is resynced once after
    /// zoom settles (see `zoomSettleFrames`). Returns whether a font change was
    /// applied this frame.
    @discardableResult
    func applyPendingFontSizeIfNeeded() -> Bool {
        guard let target = pendingFontSize, let surface else { return false }
        pendingFontSize = nil
        guard target != liveFontSize else { return false }
        liveFontSize = target
        MobileDebugLog.anchormux("zoom.apply \(target) eff=\(effectiveGrid.map { "\($0.cols)x\($0.rows)" } ?? "nil")")
        // Absolute set: the prior `±1` binding action drove libghostty's own
        // font counter independently of our clamp, so a fast burst could push
        // it past `maximumSize` toward the 255pt ceiling and collapse the grid.
        // An absolute `set_font_size:<target>` keeps libghostty in lockstep
        // with `liveFontSize`, which we keep inside [minimumSize, maximumSize].
        let action = "set_font_size:\(target)"
        Self.outputQueue.async {
            action.withCString { pointer in
                _ = ghostty_surface_binding_action(surface, pointer, UInt(action.utf8.count))
            }
        }
        // Render the new font (the grid reflows inside the current surface) but
        // do NOT resize the surface this frame. Resizing the render target on
        // every zoom step reallocates the IOSurface and stalls `render_now`'s
        // GPU frame wait (the wedge). Defer one geometry resync until zoom goes
        // quiet via the settle counter, re-armed on every apply.
        needsDraw = true
        zoomSettleFrames = Self.zoomSettleFrameThreshold
        return true
    }

    /// Set the live zoom to an absolute size (clamped to the font range),
    /// driving the same coalesced apply path as a pinch step. Used by the
    /// zoom-control overlay's reset / restore-built-in actions.
    private func applyAbsoluteFontSize(_ target: Float32) {
        guard surface != nil else { return }
        let clamped = min(
            max(target, MobileTerminalFontPreference.minimumSize),
            MobileTerminalFontPreference.maximumSize
        )
        pendingFontSize = clamped
        MobileDebugLog.anchormux("zoom.absolute target=\(target) clamped=\(clamped) live=\(liveFontSize)")
        scheduleDisplayLinkWork()
    }

    /// Present (or refresh) the zoom-control HUD and restart its auto-fade
    /// timer. Called on every zoom step so the header tracks the live size.
    func showZoomOverlay() {
        let overlay = ensureZoomOverlay()
        overlay.updateZoom(points: pendingFontSize ?? liveFontSize)
        zoomOverlayLastInteraction = CACurrentMediaTime()
        if !zoomOverlayShown {
            zoomOverlayShown = true
            overlay.isHidden = false
            bringSubviewToFront(overlay)
            UIView.animate(withDuration: 0.18) { overlay.alpha = 1 }
        }
        layoutZoomOverlay()
    }

    func fadeOutZoomOverlay() {
        guard zoomOverlayShown, let overlay = zoomOverlay else { return }
        zoomOverlayShown = false
        UIView.animate(
            withDuration: 0.3,
            animations: { overlay.alpha = 0 },
            completion: { [weak overlay] _ in
                if overlay?.alpha == 0 { overlay?.isHidden = true }
            }
        )
    }

    private func ensureZoomOverlay() -> MobileTerminalZoomControlOverlay {
        if let zoomOverlay { return zoomOverlay }
        let overlay = MobileTerminalZoomControlOverlay()
        overlay.alpha = 0
        overlay.isHidden = true
        overlay.layer.zPosition = 1100
        overlay.onInteraction = { [weak self] in
            self?.zoomOverlayLastInteraction = CACurrentMediaTime()
        }
        overlay.onResetToDefault = { [weak self] in
            guard let self else { return }
            let target = self.zoomPreference.savedFontSize
                ?? MobileTerminalFontPreference.defaultSize
            self.applyAbsoluteFontSize(target)
            self.zoomOverlay?.updateZoom(points: target)
        }
        overlay.onSaveAsDefault = { [weak self] in
            guard let self else { return }
            self.zoomPreference.save(self.pendingFontSize ?? self.liveFontSize)
        }
        overlay.onRestoreBuiltIn = { [weak self] in
            guard let self else { return }
            self.zoomPreference.clear()
            self.applyAbsoluteFontSize(MobileTerminalFontPreference.defaultSize)
            self.zoomOverlay?.updateZoom(points: MobileTerminalFontPreference.defaultSize)
        }
        addSubview(overlay)
        zoomOverlay = overlay
        layoutZoomOverlay()
        return overlay
    }

    /// Center the zoom HUD in the area above the keyboard / toolbar.
    func layoutZoomOverlay() {
        guard let zoomOverlay else { return }
        let fitting = zoomOverlay.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        let size = CGSize(width: max(fitting.width, 220), height: max(fitting.height, 1))
        let bottomReserve = reservedToolbarHeight + max(0, keyboardHeight)
        let availableH = max(1, bounds.height - bottomReserve)
        zoomOverlay.bounds = CGRect(origin: .zero, size: size)
        zoomOverlay.center = CGPoint(x: bounds.midX, y: availableH * 0.45)
    }

    #if DEBUG
    /// Repro hook for the `CMUX_ZOOM_STRESS` harness: drive one font-zoom
    /// step exactly as pinch / the accessory buttons do, so the harness can
    /// hammer the zoom path and reproduce the fast-zoom crash locally.
    func debugStressZoomStep(_ direction: TerminalFontZoomDirection) {
        performFontZoom(direction)
    }
    #endif

}

#endif
