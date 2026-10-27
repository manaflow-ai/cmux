public import AppKit
import CmuxNextDesign
import CmuxNextWakeups
import GhosttyNextKit
import IOSurface

/// Drawing while the window is seen, and the frame a paused surface keeps.
extension TerminalSurfaceView {
    /// Follows `window`'s occlusion family while shown (``observeWindow``): a covered window's surface
    /// stops drawing, a window seen again draws its current content. A content-stage subscriber: it
    /// pauses before diagnostics read the window.
    func watchOcclusionFamily(of window: NSWindow) -> WindowOcclusionSubscription {
        WindowOcclusionFamily.of(window).subscribe(.content, owner: "TerminalSurfaceView") { [weak self] _ in
            self?.updateOcclusion()
        }
    }

    /// `ghostty_surface_set_occlusion` (ghostty.h:1442) per ``WindowDrawPolicy``. Paused surfaces
    /// keep parsing output; Ghostty draws the current content on its `.visible` message. GPU memory
    /// comes back before that draw and goes after a pause (``TerminalGPUResidencyGate``). A window an
    /// opaque cmux window covers is occluded too (its ``WindowOcclusionFamily``, p03-rendering-097).
    func updateOcclusion() {
        guard let surface else { return }
        var inputs = WindowDrawPolicy.inputs(for: self, suspended: isRenderingSuspended, forced: mirrorDemand > 0)
        if let window, WindowOcclusionFamily.installed(on: window)?.isOccluded == true { inputs.windowVisible = false }
        pause = inputs.pause
        let releases = pause != nil && releasesGPUWhilePaused
        gpu.acquire(releases: releases)?.setResident(true, of: self)
        defer { gpu.release(releases: releases)?.setResident(false, of: self) }
        guard (pause == nil) != lastOcclusionVisible else { return }
        lastOcclusionVisible = pause == nil
        heldFrame.hold(volatile: pause != nil, in: frameSource)
        // SAFETY: the view's live surface (`surface`).
        unsafe ghostty_surface_set_occlusion(surface, pause == nil)
    }

    /// The presented frame for one reader (hover pictures; ``TerminalHeldFrame/beginRead(from:)``).
    func beginFrameRead() -> IOSurface? { heldFrame.beginRead(from: frameSource) }

    func endFrameRead(_ frame: IOSurface) { heldFrame.endRead(frame) }
}
