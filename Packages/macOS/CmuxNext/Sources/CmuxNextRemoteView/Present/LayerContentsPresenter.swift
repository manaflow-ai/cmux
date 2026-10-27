import AppKit
import Metal
import QuartzCore

/// Variant A: the decoded IOSurface presented off the main thread. A frame
/// posts to the mailbox; the first post schedules one draw on the render
/// queue (`MetalYUVRenderer`: the surface's planes as Metal textures, no
/// copy), which presents with `presentsWithTransaction = false`, so a frame
/// reaches the screen with no main-thread turn. Main hears only of a new
/// frame size and of the first frame after `armFrameShown()`; `shownFrame`
/// reads the mailbox. Chrome presents the same way, from the GPU thread and
/// never the browser's UI thread (gpu/ipc/service/image_transport_surface_overlay_mac.h).
/// The render queue's draw holds the layer, so a pane torn down mid-draw
/// never frees it under the renderer.
@MainActor
final class LayerContentsPresenter: RemoteFramePresenter {
    let kind = RemotePresenterKind.layerContents
    private let metalLayer = CAMetalLayer()
    var layer: CALayer { metalLayer }
    var onFrameSize: ((CGSize) -> Void)?
    var onFrameShown: (() -> Void)?
    private nonisolated let mailbox = LatestFrameMailbox<RemoteDecodedFrame>()
    private nonisolated let renderer: MetalYUVRenderer
    private var frameSize: CGSize = .zero
    /// Main-thread turns this presenter took (size changes and answered arms), for tests.
    private(set) var mainTurns = 0

    /// Nil where Metal is missing.
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
            guard let shown = await renderer.drawNewest(from: mailbox),
                  shown.noticeAsked || shown.replaced?.pixelSize != shown.frame.pixelSize else { return }
            await self?.shownChanged()
        }
    }

    nonisolated var discardedFrames: Int { mailbox.discardedCount }

    var shownFrame: RemoteDecodedFrame? { mailbox.lastShown }

    func setBackingScale(_ scale: CGFloat) {
        metalLayer.contentsScale = scale
    }

    /// The next shown frame calls `onFrameShown`, and `onFrameSize` with its size even when it is the
    /// size before (a restarted owner may have shown something else meanwhile).
    func armFrameShown() {
        frameSize = .zero
        mailbox.armShownNotice()
    }

    /// A new frame size, or the first frame since an arm: the newest shown frame's size wins.
    private func shownChanged() {
        mainTurns += 1
        if let size = mailbox.lastShown?.pixelSize, size != frameSize {
            frameSize = size
            onFrameSize?(size)
        }
        onFrameShown?()
    }
}

/// No implicit animations on video layers: a new frame or a moved image
/// must appear at once.
enum RemoteLayerActions {
    static let none: [String: any CAAction] = [
        "contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "frame": NSNull(),
        "hidden": NSNull(), "opacity": NSNull(), "sublayers": NSNull(),
    ]
}
