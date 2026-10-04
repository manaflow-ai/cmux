import AppKit
import CoreVideo
import IOSurface

/// Variant A: the decoded IOSurface becomes the layer's contents. Zero copy;
/// the window server converts NV12 to RGB when it composites. A frame posts
/// to the mailbox; the first post schedules one main-actor drain that shows
/// the newest frame.
@MainActor
final class LayerContentsPresenter: RemoteFramePresenter {
    let kind = RemotePresenterKind.layerContents
    let layer = CALayer()
    var onFrameSize: ((CGSize) -> Void)?
    private nonisolated let mailbox = LatestFrameMailbox<RemoteDecodedFrame>()
    private var frameSize: CGSize = .zero

    init() {
        layer.contentsGravity = .topLeft
        layer.isOpaque = true
        layer.actions = RemoteLayerActions.none
    }

    nonisolated func present(_ frame: RemoteDecodedFrame) {
        guard mailbox.post(frame) else { return }
        Task { @MainActor [weak self] in self?.drain() }
    }

    nonisolated var discardedFrames: Int { mailbox.discardedCount }

    func setBackingScale(_ scale: CGFloat) {
        layer.contentsScale = scale
    }

    private func drain() {
        guard let frame = mailbox.take() else { return }
        guard let surface = CVPixelBufferGetIOSurface(frame.pixelBuffer)?.takeUnretainedValue() else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.contents = surface
        CATransaction.commit()
        reportSize(frame.pixelSize)
    }

    private func reportSize(_ size: CGSize) {
        guard size != frameSize else { return }
        frameSize = size
        onFrameSize?(size)
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
