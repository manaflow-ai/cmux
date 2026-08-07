#if DEBUG
import CmuxFoundation
import Foundation

/// Serializes window captures and disables a compositor that has timed out.
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
        _ admission: WindowScreenshotCaptureAdmission,
        screenCaptureKitDidTimeOut: Bool
    ) {
        guard admission.coordinatorID == id, admission.claimRetirement() else {
            return
        }
        if screenCaptureKitDidTimeOut {
            screenCaptureKitIsAvailable.storeRelease(false)
        }
        captureIsAvailable.storeRelease(true)
    }
}
#endif
