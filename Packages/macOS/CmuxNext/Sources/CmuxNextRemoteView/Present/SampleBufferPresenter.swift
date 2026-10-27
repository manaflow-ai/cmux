import AppKit
import AVFoundation
import CmuxNextWakeups
import CoreMedia

/// Variant C: `AVSampleBufferDisplayLayer` with display-immediately samples
/// (no timebase, no queue: each sample replaces the shown one). The plan
/// reports this path to backlog above 60 fps; the mailbox still drops to the
/// newest frame before the enqueue.
@MainActor
final class SampleBufferPresenter: RemoteFramePresenter {
    let kind = RemotePresenterKind.sampleBuffer
    private let displayLayer = AVSampleBufferDisplayLayer()
    var layer: CALayer { displayLayer }
    var onFrameSize: ((CGSize) -> Void)?
    var onFrameShown: (() -> Void)?
    private nonisolated let mailbox = LatestFrameMailbox<RemoteDecodedFrame>()
    private var frameSize: CGSize = .zero
    private(set) var shownFrame: RemoteDecodedFrame?
    private nonisolated let mainWork: MainWorkScheduler
    private nonisolated let showOwner: MainTaskOwner

    init(mainWork: MainWorkScheduler) {
        self.mainWork = mainWork
        showOwner = mainWork.board.owner(RemoteFramePresenters.showOwner)
        displayLayer.videoGravity = .resize
        displayLayer.isOpaque = true
        displayLayer.actions = RemoteLayerActions.none
    }

    nonisolated func present(_ frame: RemoteDecodedFrame) {
        guard mailbox.post(frame) else { return }
        // node-free: the pane's frame gate closes when it hides, so a hidden pane posts nothing.
        mainWork.postFromAnyThread(.visible, owner: showOwner) { [weak self] in self?.drain() }
    }

    nonisolated var discardedFrames: Int { mailbox.discardedCount }

    func setBackingScale(_ scale: CGFloat) {
        displayLayer.contentsScale = scale
    }

    private func drain() {
        guard let frame = mailbox.take(), let sample = Self.immediateSample(frame.pixelBuffer) else { return }
        let renderer = displayLayer.sampleBufferRenderer
        if renderer.status == .failed { renderer.flush() }
        renderer.enqueue(sample)
        shownFrame = frame
        if frame.pixelSize != frameSize {
            frameSize = frame.pixelSize
            onFrameSize?(frame.pixelSize)
        }
        onFrameShown?()
    }

    /// A sample around the decoded picture, marked to display at once.
    static func immediateSample(_ pixelBuffer: CVPixelBuffer) -> CMSampleBuffer? {
        var format: CMVideoFormatDescription?
        // SAFETY: Core Media writes one +1 description to the local `format`, live for the call.
        guard unsafe CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &format) == noErr,
            let format else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        // SAFETY: Core Media copies the one timing entry from the local `timing` and writes one
        // +1 sample to the local `sample`; both are live for the call.
        guard unsafe CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescription: format,
            sampleTiming: &timing, sampleBufferOut: &sample) == noErr, let sample else { return nil }
        // The attachments array holds the sample's own mutable dictionaries (toll-free
        // bridged), so setting the key on the first one marks the sample itself.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           let first = (attachments as NSArray).firstObject as? NSMutableDictionary {
            first[kCMSampleAttachmentKey_DisplayImmediately] = true
        }
        return sample
    }
}
