#if DEBUG
import Foundation

/// Identifies one admitted window-screenshot capture and its compositor policy.
struct WindowScreenshotCaptureAdmission: Sendable, Equatable {
    let id: UUID
    let allowsScreenCaptureKit: Bool
}
#endif
