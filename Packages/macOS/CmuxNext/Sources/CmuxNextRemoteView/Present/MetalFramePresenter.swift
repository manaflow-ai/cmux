import AppKit
import Metal
import QuartzCore

/// Variant B (the default candidate): a `CAMetalLayer` with three drawables.
/// A decoded frame posts to the mailbox; the first post schedules one draw
/// on the render queue, which takes the newest frame, so a burst collapses
/// to its last frame and at most one frame is in flight. Present hands the
/// drawable to the window server at once (display sync off), not at the next
/// refresh, and the third drawable keeps `nextDrawable` from waiting on the
/// two the compositor may still hold; no display link runs, so there are no
/// wakeups while no frames arrive.
@MainActor
final class MetalFramePresenter: RemoteFramePresenter {
    let kind = RemotePresenterKind.metal
    private let metalLayer = CAMetalLayer()
    var layer: CALayer { metalLayer }
    var onFrameSize: ((CGSize) -> Void)?
    private nonisolated let mailbox = LatestFrameMailbox<RemoteDecodedFrame>()
    private nonisolated let renderer: MetalYUVRenderer
    private var frameSize: CGSize = .zero

    init?() {
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        // Two drawables made `nextDrawable` wait for the compositor to release one.
        metalLayer.maximumDrawableCount = 3
        // On, `present` held each frame for the next refresh before the window server saw it.
        metalLayer.displaySyncEnabled = false
        metalLayer.isOpaque = true
        metalLayer.presentsWithTransaction = false
        metalLayer.actions = RemoteLayerActions.none
        guard let renderer = MetalYUVRenderer(layer: metalLayer) else { return nil }
        self.renderer = renderer
    }

    nonisolated func present(_ frame: RemoteDecodedFrame) {
        guard mailbox.post(frame) else { return }
        renderer.queue.async { [self] in drainOnRenderQueue() }
    }

    nonisolated var discardedFrames: Int { mailbox.discardedCount }

    func setBackingScale(_ scale: CGFloat) {
        metalLayer.contentsScale = scale
    }

    private nonisolated func drainOnRenderQueue() {
        guard let frame = mailbox.take(), renderer.render(frame) else { return }
        let size = frame.pixelSize
        Task { @MainActor [weak self] in self?.reportSize(size) }
    }

    private func reportSize(_ size: CGSize) {
        guard size != frameSize else { return }
        frameSize = size
        onFrameSize?(size)
    }
}
