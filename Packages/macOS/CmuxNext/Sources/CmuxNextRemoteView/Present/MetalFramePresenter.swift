import AppKit
import Metal
import QuartzCore

/// Variant B (the default candidate): a `CAMetalLayer` with two drawables.
/// A decoded frame posts to the mailbox; the first post schedules one draw
/// on the render queue, which takes the newest frame, so a burst collapses
/// to its last frame and at most one frame is in flight. Present happens at
/// the next refresh after the draw; no display link runs, so there are no
/// wakeups while no frames arrive.
@MainActor
final class MetalFramePresenter: RemoteFramePresenter {
    let kind = RemotePresenterKind.metal
    private let metalLayer = CAMetalLayer()
    var layer: CALayer { metalLayer }
    var onFrameSize: ((CGSize) -> Void)?
    var onFrameShown: (() -> Void)?
    private nonisolated let mailbox = LatestFrameMailbox<RemoteDecodedFrame>()
    private nonisolated let renderer: MetalYUVRenderer
    private var frameSize: CGSize = .zero
    private(set) var shownFrame: RemoteDecodedFrame?

    init?() {
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.maximumDrawableCount = 2
        metalLayer.isOpaque = true
        metalLayer.presentsWithTransaction = false
        metalLayer.actions = RemoteLayerActions.none
        guard let renderer = MetalYUVRenderer(layer: SharedMetalLayer(metalLayer)) else { return nil }
        self.renderer = renderer
    }

    nonisolated func present(_ frame: RemoteDecodedFrame) {
        guard mailbox.post(frame) else { return }
        Task { [renderer, mailbox, weak self] in
            guard let shown = await renderer.drawNewest(from: mailbox) else { return }
            await self?.rendered(shown)
        }
    }

    nonisolated var discardedFrames: Int { mailbox.discardedCount }

    func setBackingScale(_ scale: CGFloat) {
        metalLayer.contentsScale = scale
    }

    private func rendered(_ frame: RemoteDecodedFrame) {
        shownFrame = frame
        reportSize(frame.pixelSize)
        onFrameShown?()
    }

    private func reportSize(_ size: CGSize) {
        guard size != frameSize else { return }
        frameSize = size
        onFrameSize?(size)
    }
}
