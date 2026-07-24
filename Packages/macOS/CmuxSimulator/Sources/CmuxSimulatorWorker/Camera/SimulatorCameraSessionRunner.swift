import Foundation

// SAFETY: the private serial queue owns every call into the capture session,
// and the runner exposes no mutable state outside that queue.
final class SimulatorCameraSessionRunner: @unchecked Sendable {
    private let queue = DispatchQueue(
        label: "com.cmux.simulator.camera.session",
        qos: .userInitiated
    )

    func start(_ box: SimulatorCameraCaptureSessionBox) async {
        await withCheckedContinuation { continuation in
            queue.async {
                box.session.startRunning()
                continuation.resume()
            }
        }
    }

    func stop(_ box: SimulatorCameraCaptureSessionBox) async {
        await withCheckedContinuation { continuation in
            queue.async {
                box.session.stopRunning()
                continuation.resume()
            }
        }
    }

    func stopDetached(_ box: SimulatorCameraCaptureSessionBox) {
        queue.async {
            box.session.stopRunning()
        }
    }
}
