#if DEBUG
import Foundation

/// Serializes window captures and disables a compositor that has timed out.
actor WindowScreenshotCaptureCoordinator {
    private var activeCaptureID: UUID?
    private var screenCaptureKitTimedOut = false

    func claim() -> WindowScreenshotCaptureAdmission? {
        guard !Task.isCancelled, activeCaptureID == nil else { return nil }
        let id = UUID()
        activeCaptureID = id
        return WindowScreenshotCaptureAdmission(
            id: id,
            allowsScreenCaptureKit: !screenCaptureKitTimedOut
        )
    }

    func finish(
        _ admission: WindowScreenshotCaptureAdmission,
        screenCaptureKitDidTimeOut: Bool
    ) {
        guard activeCaptureID == admission.id else { return }
        if screenCaptureKitDidTimeOut {
            self.screenCaptureKitTimedOut = true
        }
        activeCaptureID = nil
    }

    /// Retires an admission that arrives after its synchronous socket waiter timed out.
    func finishAfterClaim(
        _ claimTask: Task<WindowScreenshotCaptureAdmission?, Never>
    ) async {
        guard let admission = await claimTask.value else { return }
        finish(admission, screenCaptureKitDidTimeOut: false)
    }
}
#endif
