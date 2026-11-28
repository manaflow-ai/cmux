import AppKit
import AVFoundation
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
    private nonisolated let mailbox = LatestFrameMailbox<RemoteDecodedFrame>()
    private var frameSize: CGSize = .zero

    init() {
        displayLayer.videoGravity = .resize
        displayLayer.isOpaque = true
        displayLayer.actions = RemoteLayerActions.none
    }

    nonisolated func present(_ frame: RemoteDecodedFrame) {
        guard mailbox.post(frame) else { return }
        Task { @MainActor [weak self] in self?.drain() }
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
        if frame.pixelSize != frameSize {
            frameSize = frame.pixelSize
            onFrameSize?(frame.pixelSize)
        }
    }

    /// A sample around the decoded picture, marked to display at once.
    private static func immediateSample(_ pixelBuffer: CVPixelBuffer) -> CMSampleBuffer? {
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &format) == noErr,
            let format else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescription: format,
            sampleTiming: &timing, sampleBufferOut: &sample) == noErr, let sample else { return nil }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dictionary,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }
}
