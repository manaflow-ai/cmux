#if DEBUG
import CmuxFoundation

/// Serializes screenshot operations until every asynchronous backend retires.
nonisolated final class WindowScreenshotCaptureCoordinator: Sendable {
    private let captureIsAvailable = AtomicBooleanGate(true)

    func claim() -> WindowScreenshotCaptureLease? {
        guard captureIsAvailable.compareExchange(expected: true, desired: false) else {
            return nil
        }
        return WindowScreenshotCaptureLease(coordinator: self)
    }

    func retireCapture() {
        captureIsAvailable.storeRelease(true)
    }
}
#endif
