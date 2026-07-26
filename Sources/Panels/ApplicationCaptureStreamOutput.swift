import AVFoundation
import CoreMedia
import ScreenCaptureKit

/// ScreenCaptureKit calls this output on the main queue so every display-layer
/// access is serialized with the owning `ApplicationCaptureView`.
final class ApplicationCaptureStreamOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    let sampleQueue = DispatchQueue.main
    private let displayLayer: AVSampleBufferDisplayLayer

    init(displayLayer: AVSampleBufferDisplayLayer) {
        self.displayLayer = displayLayer
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .screen, sampleBuffer.isValid else { return }
        displayLayer.enqueue(sampleBuffer)
    }
}
