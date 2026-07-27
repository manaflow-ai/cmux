import AVFoundation
import CoreMedia
import ScreenCaptureKit

/// ScreenCaptureKit calls this output on the main queue so every display-layer
/// access is serialized with the owning `ApplicationCaptureView`.
final class ApplicationCaptureStreamOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    let sampleQueue = DispatchQueue.main
    private let displayLayer: AVSampleBufferDisplayLayer
    private let onFrame: @MainActor (CGRect) -> Void

    init(
        displayLayer: AVSampleBufferDisplayLayer,
        onFrame: @escaping @MainActor (CGRect) -> Void
    ) {
        self.displayLayer = displayLayer
        self.onFrame = onFrame
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .screen, sampleBuffer.isValid else { return }
        MainActor.assumeIsolated {
            if let frame = Self.screenRect(in: sampleBuffer) {
                onFrame(frame)
            }
            displayLayer.enqueue(sampleBuffer)
        }
    }

    private static func screenRect(in sampleBuffer: CMSampleBuffer) -> CGRect? {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]],
        let frame = attachments.first?[.screenRect] as? CGRect,
        frame.width > 0,
        frame.height > 0 else {
            return nil
        }
        return frame
    }
}
