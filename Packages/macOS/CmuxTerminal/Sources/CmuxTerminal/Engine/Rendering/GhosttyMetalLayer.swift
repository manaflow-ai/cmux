public import CmuxTerminalCore
public import QuartzCore
internal import Foundation

/// Lightweight instrumentation to detect whether Ghostty is actually requesting Metal drawables.
/// This helps catch "frozen until refocus" regressions without relying on screenshots (which can
/// mask redraw issues by forcing a window server flush).
///
/// Isolation design: `nextDrawable()` is invoked by the ghostty renderer on
/// its own thread, so the layer cannot be `@MainActor`; the mutable
/// instrumentation state is guarded by one lock (the sanctioned shape for
/// tiny values read by synchronous off-isolation code), and frame
/// notifications hop to the main actor before touching the receiver.
public final class GhosttyMetalLayer: CAMetalLayer {
    private let lock = NSLock()
    // SAFETY: all four are guarded by `lock`; written/read from the renderer
    // thread (`nextDrawable()`) and the main actor (configuration, debug HUD).
    nonisolated(unsafe) private var drawableCount: Int = 0
    nonisolated(unsafe) private var lastDrawableTime: CFTimeInterval = 0
    nonisolated(unsafe) private weak var frameReceiver: (any TerminalRenderedFrameReceiving)?
    nonisolated(unsafe) private var renderDemand: (any RenderDemandGating)?

    /// Injects the rendered-frame demand gate that decides whether vending a
    /// drawable should notify the receiver.
    public func setRenderDemand(_ renderDemand: (any RenderDemandGating)?) {
        lock.lock()
        self.renderDemand = renderDemand
        lock.unlock()
    }

    /// Attaches the view that receives coalesced rendered-frame updates.
    public func setFrameReceiver(_ frameReceiver: (any TerminalRenderedFrameReceiving)?) {
        lock.lock()
        self.frameReceiver = frameReceiver
        lock.unlock()
    }

    /// The number of drawables vended so far and the media time of the last
    /// one, for debug HUDs.
    public func debugStats() -> (count: Int, last: CFTimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        return (drawableCount, lastDrawableTime)
    }

    override public func nextDrawable() -> (any CAMetalDrawable)? {
        guard let drawable = super.nextDrawable() else { return nil }
        // One critical section for the instrumentation write and both
        // injected-collaborator reads; the render thread takes this lock once
        // per vended drawable.
        lock.lock()
        drawableCount += 1
        lastDrawableTime = CACurrentMediaTime()
        let renderDemand = renderDemand
        let frameReceiver = frameReceiver
        lock.unlock()
        guard renderDemand?.isActive == true else { return drawable }
        if let frameReceiver {
            // Hop to the main actor exactly like the legacy
            // DispatchQueue.main.async dispatch (the main-actor executor is
            // the main queue); the receiver coalesces bursts on arrival.
            Task { @MainActor [weak frameReceiver] in
                frameReceiver?.enqueueRenderedFrameUpdate()
            }
        }
        return drawable
    }
}
