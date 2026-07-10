@preconcurrency import AVFoundation

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
