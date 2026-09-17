internal import GhosttyKit
#if DEBUG
internal import AppKit
internal import CMUXDebugLog
internal import QuartzCore
#endif

extension TerminalSurface {
    /// Applies one renderer/PTY size mutation through the observable owner boundary.
    @MainActor
    func applySurfaceSize(
        _ surface: ghostty_surface_t,
        width: UInt32,
        height: UInt32,
        caller: StaticString
    ) {
        #if DEBUG
        let previous = ghostty_surface_size(surface)
        #endif

        ghostty_surface_set_size(surface, width, height)

        #if DEBUG
        let applied = ghostty_surface_size(surface)
        logDebugEvent(
            "surface.size.apply surface=\(id.uuidString.prefix(8)) caller=\(caller) " +
            "grid=\(previous.columns)x\(previous.rows)->\(applied.columns)x\(applied.rows) " +
            "pixels=\(previous.width_px)x\(previous.height_px)->\(applied.width_px)x\(applied.height_px) " +
            "target=\(width)x\(height) cell=\(applied.cell_width_px)x\(applied.cell_height_px) " +
            sizeApplicationDebugContext()
        )
        #endif
    }

    #if DEBUG
    /// Samples host state at the size write without forcing layout or a redraw.
    /// The drawable sequence counts acquisitions, not completed GPU presents.
    @MainActor
    private func sizeApplicationDebugContext() -> String {
        let state = "generation=\(runtimeSurfaceGeneration) " +
            "deferred=\(surfaceResizeAuthority?.isRendererResizeDeferred == true ? 1 : 0) " +
            "portalVisible=\(rendererPortalVisible ? 1 : 0) health=\(renderHealth.rawValue)"
        guard let view = attachedView else { return state + " view=nil" }
        let drawable = (view.layer as? CAMetalLayer).map { NSStringFromSize($0.drawableSize) } ?? "nil"
        return state + " view=\(NSStringFromSize(view.bounds.size)) " +
            "layer=\(NSStringFromSize(view.layer?.bounds.size ?? .zero)) drawable=\(drawable) " +
            "scale=\(view.layer?.contentsScale ?? 0) drawableSequence=\(view.renderedFrameSequence) " +
            "inWindow=\(view.window != nil ? 1 : 0) liveResize=\(view.inLiveResize ? 1 : 0)"
    }
    #endif
}
