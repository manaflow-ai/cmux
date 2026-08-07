#if DEBUG
import CmuxFoundation
import Foundation

/// Serializes captures and pauses the compositor while a timed-out attempt retires.
nonisolated final class WindowScreenshotCaptureCoordinator: Sendable {
    private let id = UUID()
    private let captureIsAvailable = AtomicBooleanGate(true)
    private let screenCaptureKitIsAvailable = AtomicBooleanGate(true)

    func claim() -> WindowScreenshotCaptureAdmission? {
        guard captureIsAvailable.compareExchange(expected: true, desired: false) else {
            return nil
        }
        return WindowScreenshotCaptureAdmission(
            id: UUID(),
            allowsScreenCaptureKit: screenCaptureKitIsAvailable.loadAcquire(),
            coordinatorID: id
        )
    }

    func finish(
        _ admission: WindowScreenshotCaptureAdmission
    ) {
        guard admission.coordinatorID == id, admission.claimRetirement() else {
            return
        }
        captureIsAvailable.storeRelease(true)
    }

    func disableScreenCaptureKitUntilAttemptRetires() {
        screenCaptureKitIsAvailable.storeRelease(false)
    }

    func screenCaptureKitAttemptDidRetire() {
        screenCaptureKitIsAvailable.storeRelease(true)
    }
}
#endif
