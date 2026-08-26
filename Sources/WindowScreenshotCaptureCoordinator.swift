#if DEBUG
import CmuxFoundation

/// Bounds each screenshot backend independently until its task retires.
final class WindowScreenshotCaptureCoordinator: Sendable {
    private let appKitIsAvailable = AtomicBooleanGate(true)
    private let screenCaptureKitIsAvailable = AtomicBooleanGate(true)

    func claimAppKit() -> WindowScreenshotCaptureLease? {
        guard appKitIsAvailable.compareExchange(expected: true, desired: false) else {
            return nil
        }
        return WindowScreenshotCaptureLease { [appKitIsAvailable] in
            appKitIsAvailable.storeRelease(true)
        }
    }

    func claimScreenCaptureKit() -> WindowScreenshotCaptureLease? {
        guard screenCaptureKitIsAvailable.compareExchange(
            expected: true,
            desired: false
        ) else {
            return nil
        }
        return WindowScreenshotCaptureLease { [screenCaptureKitIsAvailable] in
            screenCaptureKitIsAvailable.storeRelease(true)
        }
    }
}
#endif
