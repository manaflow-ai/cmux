public import AppKit
import CmuxNextDesign
import CmuxNextWakeups
import GhosttyNextKit
import IOSurface

/// Drawing while the surface and its window are shown, and the frame a paused surface keeps.
///
/// One draw truth per surface (principled-audit restoreFrameHold R1/R2): the pause is a pure function of the
/// surface's visibility node (``windowNode``: its tab, pane, AppKit's hidden state, parking, its window) and its
/// window's node (``WindowVisibilitySource``: AppKit's occlusion, minimize, the app, and the window's
/// ``WindowOcclusionFamily``), computed again on every edge of either (``syncWindowState()``, ``watchWindowNode(of:)``).
/// `WindowDrawPolicy.isDrawable` and the blank-pane invariant read the same window node.
extension TerminalSurfaceView {
    /// Follows `window`'s node while shown (``observeWindow``): a covered window's surface stops drawing, a window
    /// seen again draws its current content.
    func watchWindowNode(of window: NSWindow) -> VisibilitySubscription {
        WindowVisibilitySource.of(window).node.subscribe(owner: "TerminalSurfaceView.window") { [weak self] _ in
            self?.updateOcclusion()
        }
    }

    /// The drawing inputs now, each read from a node (``SurfaceDrawInputs``); nothing walks AppKit's view tree.
    var drawInputs: SurfaceDrawInputs {
        SurfaceDrawInputs(
            inWindow: window != nil,
            windowVisible: window.map { WindowVisibilitySource.of($0).node.isVisible } ?? false,
            hidden: visibilityNode.effective == .hidden,
            // ``syncPlacement()`` makes the window node own-hidden only with no window or a container above parked.
            parked: window != nil && windowNode.own == .hidden,
            suspended: isRenderingSuspended,
            forced: mirrorDemand > 0,
            awaitingContent: awaitsContent,
            drawWhenOccluded: WindowDrawPolicy.drawsWhenOccluded
        )
    }

    /// `ghostty_surface_set_occlusion` (ghostty.h:1442) per ``drawInputs``. Paused surfaces
    /// keep parsing output; Ghostty draws the current content on its `.visible` message. GPU memory
    /// comes back before that draw and goes after a pause (``TerminalGPUResidencyGate``).
    /// A shown surface whose window stays off screen counts as away (``TerminalOffScreenRelease``).
    func updateOcclusion() {
        guard surface != nil else { return }
        let inputs = drawInputs
        pause = inputs.pause
        let shownOffScreen = isShown && inputs.windowOffScreen
        if let deadline = offScreenRelease.follow(shownOffScreen: shownOffScreen, windowOnScreen: inputs.windowOnScreen) {
            deadline.schedule(after: WindowDrawPolicy.offScreenGPUReleaseDelay) { [weak self] in self?.offScreenDelayPassed() }
        }
        let releases = pause != nil && (releasesGPUWhilePaused || offScreenRelease.isDue)
        gpu.acquire(releases: releases)?.setResident(true, of: self)
        defer { gpu.release(releases: releases)?.setResident(false, of: self) }
        // What Ghostty was last told (``lastOcclusionVisible``) against the pause now: only a change is sent.
        guard (pause == nil) != lastOcclusionVisible else { return }
        lastOcclusionVisible = pause == nil
        #if DEBUG || CMUX_BENCH_HOOKS
        if pause == nil { showRecord.unpaused() }
        #endif
        heldFrame.hold(volatile: pause != nil, in: frameSource)
        TerminalHostFramePresenter.setOcclusion(of: self, visible: pause == nil)  // shown: drawn frame in this commit
        session?.frameHold.surfaceDrawingChanged(self)
    }

    /// The R3 check of the draw truth (DEBUG `InputInvariantMonitor`, principled-audit restoreFrameHold): nil when the
    /// pause the surface holds is the one its nodes give now and Ghostty was told it; else what differs. A missed node
    /// edge (a stale `hidden` pause, a family flip only some readers heard) shows here.
    package var drawTruthMismatch: String? {
        guard surface != nil else { return nil }
        // AppKit hides it but its node does not: it would draw hidden. The other direction (on screen, not shown) is
        // G2's report with the node chain (``restingGridMismatch(onScreen:ownerSettled:)``), not repeated here.
        // visibility-walk-allow: the DEBUG check compares the node with AppKit's ground truth once per check, never per frame
        if window != nil, visibilityNode.own != .hidden, isHiddenOrHasHiddenAncestor {
            return "AppKit hides it, its node own \(visibilityNode.own)"
        }
        // Whether it draws, not the reason: a reason may change with no edge (a parked container under a hidden tab).
        let now = drawInputs.pause
        if (pause == nil) != (now == nil) { return "pause \(pause?.rawValue ?? "none"), its nodes give \(now?.rawValue ?? "none")" }
        if let told = lastOcclusionVisible, told != (now == nil) { return "Ghostty told drawing \(told), pause \(now?.rawValue ?? "none")" }
        return nil
    }

    /// Its window stayed off screen ``WindowDrawPolicy/offScreenGPUReleaseDelay``: the paused surface
    /// lets its GPU memory go.
    private func offScreenDelayPassed() {
        if offScreenRelease.delayPassed() { updateOcclusion() }
    }

    /// The presented frame for one reader (hover pictures; ``TerminalHeldFrame/beginRead(from:)``).
    func beginFrameRead() -> IOSurface? { heldFrame.beginRead(from: frameSource) }

    func endFrameRead(_ frame: IOSurface) { heldFrame.endRead(frame) }
}
