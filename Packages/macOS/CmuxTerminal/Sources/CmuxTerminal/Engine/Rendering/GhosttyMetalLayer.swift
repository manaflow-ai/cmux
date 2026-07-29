public import CmuxTerminalCore
public import QuartzCore
internal import CmuxFoundation
internal import Foundation

/// Lightweight instrumentation to detect whether Ghostty is actually requesting Metal drawables.
/// This helps catch "frozen until refocus" regressions without relying on screenshots (which can
/// mask redraw issues by forcing a window server flush).
///
/// `nextDrawable()` runs on Ghostty's renderer thread. Lock-free atomics hold
/// synchronous instrumentation, while an actor owns receiver and demand state
/// behind a bounded newest-value ingress.
public final class GhosttyMetalLayer: CAMetalLayer {
    private let renderDemand: (any RenderDemandGating)?
    private let localRenderDemand: (any RenderDemandGating)?
    private let keyboardCopyModeCursorDemand: (any RenderDemandGating)?
    private let frameDeliveryCoordinator: RenderedFrameDeliveryCoordinator
    private let drawableCount: AtomicUInt64Value
    private let lastDrawableTimeBits: AtomicUInt64Value

    /// Creates a layer whose renderer notifications are gated by the supplied
    /// demand counters.
    public init(
        renderDemand: (any RenderDemandGating)?,
        localRenderDemand: (any RenderDemandGating)?,
        keyboardCopyModeCursorDemand: (any RenderDemandGating)?,
        receiver: (any TerminalRenderedFrameReceiving)?
    ) {
        self.renderDemand = renderDemand
        self.localRenderDemand = localRenderDemand
        self.keyboardCopyModeCursorDemand = keyboardCopyModeCursorDemand
        self.frameDeliveryCoordinator = RenderedFrameDeliveryCoordinator(
            renderDemand: renderDemand,
            localRenderDemand: localRenderDemand,
            keyboardCopyModeCursorDemand: keyboardCopyModeCursorDemand,
            receiver: receiver
        )
        self.drawableCount = AtomicUInt64Value()
        self.lastDrawableTimeBits = AtomicUInt64Value()
        super.init()
    }

    override public init(layer: Any) {
        if let source = layer as? GhosttyMetalLayer {
            self.renderDemand = source.renderDemand
            self.localRenderDemand = source.localRenderDemand
            self.keyboardCopyModeCursorDemand = source.keyboardCopyModeCursorDemand
            self.frameDeliveryCoordinator = source.frameDeliveryCoordinator
            self.drawableCount = source.drawableCount
            self.lastDrawableTimeBits = source.lastDrawableTimeBits
        } else {
            self.renderDemand = nil
            self.localRenderDemand = nil
            self.keyboardCopyModeCursorDemand = nil
            self.frameDeliveryCoordinator = RenderedFrameDeliveryCoordinator()
            self.drawableCount = AtomicUInt64Value()
            self.lastDrawableTimeBits = AtomicUInt64Value()
        }
        super.init(layer: layer)
    }

    /// Restores an unconfigured layer from an archive.
    public required init?(coder: NSCoder) {
        self.renderDemand = nil
        self.localRenderDemand = nil
        self.keyboardCopyModeCursorDemand = nil
        self.frameDeliveryCoordinator = RenderedFrameDeliveryCoordinator()
        self.drawableCount = AtomicUInt64Value()
        self.lastDrawableTimeBits = AtomicUInt64Value()
        super.init(coder: coder)
    }

    /// Whether either gate currently requests rendered-frame delivery.
    /// Kept as one shared predicate so the renderer hot path and its focused
    /// package regression cannot drift on global-versus-local semantics.
    static func hasActiveRenderDemand(
        global: (any RenderDemandGating)?,
        local: (any RenderDemandGating)?
    ) -> Bool {
        global?.isActive == true || local?.isActive == true
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
