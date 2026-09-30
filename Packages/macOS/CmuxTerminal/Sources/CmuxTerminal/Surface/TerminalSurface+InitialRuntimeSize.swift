internal import CoreGraphics
internal import GhosttyKit

extension TerminalSurface {
    /// Sizes a freshly created runtime before it parses any output.
    ///
    /// Output buffered before the runtime existed is flushed right after this,
    /// so the grid applied here is the grid that output is parsed at.
    @MainActor
    func applyInitialRuntimeSize(
        _ createdSurface: ghostty_surface_t,
        for view: any TerminalSurfaceNativeViewing,
        scaleFactors: (x: CGFloat, y: CGFloat, layer: CGFloat)
    ) {
        let backingSize = initialRuntimeBackingSize(for: view)
        let wpx = pixelDimension(from: backingSize.width)
        let hpx = pixelDimension(from: backingSize.height)
        if wpx > 0, hpx > 0 {
            applySurfaceSize(
                createdSurface,
                width: wpx,
                height: hpx,
                caller: "runtime.create.initial"
            )
            lastPixelWidth = wpx
            lastPixelHeight = hpx
            lastUncappedPixelWidth = wpx
            lastUncappedPixelHeight = hpx
            lastXScale = scaleFactors.x
            lastYScale = scaleFactors.y
        }
        // A mirror's attach replay can arrive before its runtime exists, and
        // it addresses the remote grid. Pin to that grid before the first
        // byte is parsed: pinning afterwards resizes a live prompt, which
        // reflows the replay and clears the prompt with no shell to redraw it.
        if ioMode.usesManualIO, assignedGrid != nil {
            reapplyAssignedGrid()
        }
    }
}
