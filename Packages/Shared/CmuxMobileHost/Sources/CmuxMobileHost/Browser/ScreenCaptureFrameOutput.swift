#if os(macOS)
import CoreMedia
import Foundation
import ScreenCaptureKit

/// Receives ScreenCaptureKit samples on its queue and yields only complete
/// frames (idle and blank statuses carry no new pixels).
final class ScreenCaptureFrameOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    // Immutable after init; the continuation is Sendable.
    let frames: AsyncStream<BrowserCapturedFrame>
    // Justification: SCStream.addStreamOutput requires a sample handler queue.
    let queue = DispatchQueue(label: "cmux.mobile.browser-capture", qos: .userInteractive)
    private let continuation: AsyncStream<BrowserCapturedFrame>.Continuation
    private let origin = ContinuousClock.now

    override init() {
        (frames, continuation) = AsyncStream.makeStream(of: BrowserCapturedFrame.self, bufferingPolicy: .bufferingNewest(1))
        super.init()
    }

    func finish() {
        continuation.finish()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sample.isValid, let pixelBuffer = sample.imageBuffer,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete else { return }
        let elapsed = ContinuousClock.now - origin
        let micros = UInt64(elapsed.components.seconds) * 1_000_000 + UInt64(elapsed.components.attoseconds / 1_000_000_000_000)
        continuation.yield(BrowserCapturedFrame(pixelBuffer: pixelBuffer, captureMicros: micros))
    }
}
#endif
