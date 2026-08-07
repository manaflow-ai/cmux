#if DEBUG
import CmuxFoundation

/// Keeps screenshot admission claimed until its asynchronous operation retires.
final class WindowScreenshotCaptureLease: Sendable {
    private let coordinator: WindowScreenshotCaptureCoordinator
    private let didRetire = AtomicBooleanGate(false)

    init(coordinator: WindowScreenshotCaptureCoordinator) {
        self.coordinator = coordinator
    }

    func retire() {
        guard didRetire.compareExchange(expected: false, desired: true) else {
            return
        }
        coordinator.retireCapture()
    }
}
#endif
