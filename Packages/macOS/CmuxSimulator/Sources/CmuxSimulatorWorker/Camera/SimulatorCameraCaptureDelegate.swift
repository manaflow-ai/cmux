@preconcurrency import AVFoundation

// SAFETY: AVFoundation invokes this delegate on the one serial queue supplied
// by the producer, and the delegate owns only an immutable thread-safe ring.
final class SimulatorCameraCaptureDelegate: NSObject,
    AVCaptureVideoDataOutputSampleBufferDelegate,
    @unchecked Sendable
{
    private let surfaceRing: SimulatorCameraSurfaceRing

    init(surfaceRing: SimulatorCameraSurfaceRing) {
        self.surfaceRing = surfaceRing
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        surfaceRing.publish(pixelBuffer: pixelBuffer, fillsFrame: true)
    }
}
