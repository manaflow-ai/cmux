public import CmuxTerminalCore
public import QuartzCore
internal import CmuxFoundation

/// Lightweight instrumentation to detect whether Ghostty is actually requesting Metal drawables.
/// This helps catch "frozen until refocus" regressions without relying on screenshots (which can
/// mask redraw issues by forcing a window server flush).
///
/// `nextDrawable()` runs on Ghostty's renderer thread. Lock-free atomics hold
/// synchronous instrumentation, while an actor owns receiver and demand state
/// behind a bounded newest-value ingress.
public final class GhosttyMetalLayer: CAMetalLayer {
    private let frameDeliveryCoordinator = RenderedFrameDeliveryCoordinator()
    private let drawableCount = AtomicUInt64Value()
    private let lastDrawableTimeBits = AtomicUInt64Value()

    /// Whether either gate currently requests rendered-frame delivery.
    /// Kept as one shared predicate so the renderer hot path and its focused
    /// package regression cannot drift on global-versus-local semantics.
    static func hasActiveRenderDemand(
        global: (any RenderDemandGating)?,
        local: (any RenderDemandGating)?
    ) -> Bool {
        global?.isActive == true || local?.isActive == true
    }

    /// Configures the demand gates and view that receive coalesced frame
    /// updates.
    public func configureFrameDelivery(
        renderDemand: (any RenderDemandGating)?,
        localRenderDemand: (any RenderDemandGating)?,
        receiver: (any TerminalRenderedFrameReceiving)?
    ) {
        let coordinator = frameDeliveryCoordinator
        Task {
            await coordinator.configure(
                renderDemand: renderDemand,
                localRenderDemand: localRenderDemand,
                receiver: receiver
            )
        }
    }

    /// The number of drawables vended so far and the media time of the last
    /// one, for debug HUDs.
    public func debugStats() -> (count: Int, last: CFTimeInterval) {
        (
            Int(clamping: drawableCount.loadRelaxed()),
            CFTimeInterval(bitPattern: lastDrawableTimeBits.loadRelaxed())
        )
    }

    override public func nextDrawable() -> (any CAMetalDrawable)? {
        guard let drawable = super.nextDrawable() else { return nil }
        _ = drawableCount.wrappingIncrementRelaxed()
        lastDrawableTimeBits.storeRelaxed(CACurrentMediaTime().bitPattern)
        frameDeliveryCoordinator.requestFrame()
        return drawable
    }
}
