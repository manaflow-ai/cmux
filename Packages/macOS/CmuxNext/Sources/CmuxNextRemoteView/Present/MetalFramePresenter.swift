import AppKit
import CmuxNextWakeups
import Metal
import QuartzCore

/// Variant B (the default candidate): a `CAMetalLayer` with two drawables.
/// A decoded frame posts to the mailbox; the first post schedules one draw
/// on the render queue, which takes the newest frame, so a burst collapses
/// to its last frame and at most one frame is in flight. Present happens at
/// the next refresh after the draw; no display link runs, so there are no
/// wakeups while no frames arrive. The draw runs off main; only its report
/// (the shown frame, its size) is one visible task on the app's scheduler.
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
    private nonisolated let mainWork: MainWorkScheduler
    private nonisolated let showOwner: MainTaskOwner

    init?(mainWork: MainWorkScheduler) {
        self.mainWork = mainWork
        showOwner = mainWork.board.owner(RemoteFramePresenters.showOwner)
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
        // task-owner: one draw of the newest frame; ends when the render queue presented it.
        Task { @concurrent [renderer, mailbox, mainWork, showOwner, weak self] in
            guard let shown = await renderer.drawNewest(from: mailbox) else { return }
            // node-free: the pane's frame gate closes when it hides, so a hidden pane draws nothing.
            mainWork.postFromAnyThread(.visible, owner: showOwner) { [weak self] in self?.rendered(shown) }
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
