import AVFoundation
import CoreMedia
import ScreenCaptureKit

/// ScreenCaptureKit calls this output on `sampleQueue`. The display layer is
/// immutable after initialization and is touched only from that serial queue.
final class ApplicationCaptureStreamOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    let sampleQueue = DispatchQueue(
        label: "com.cmux.application-capture.frames",
        qos: .userInteractive
    )
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
