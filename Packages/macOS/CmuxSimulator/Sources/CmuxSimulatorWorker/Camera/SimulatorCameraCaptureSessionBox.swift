@preconcurrency import AVFoundation

/// Transfers one capture session only to the dedicated serial session runner.
/// AVFoundation synchronizes session start/stop internally; the box prevents
/// either blocking call from executing on the worker's MainActor.
final class SimulatorCameraCaptureSessionBox: @unchecked Sendable {
    let session: AVCaptureSession

    init(_ session: AVCaptureSession) {
        self.session = session
    }
}
