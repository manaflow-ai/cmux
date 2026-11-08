import Foundation

enum BrowserAutomationSnapshotResult: Sendable {
    case success(Data)
    case failure(code: String, message: String)
    case timedOut(message: String)

    /// Preserves the public wire contract for a failed browser capture.
    static func captureFailure(_ error: Error) -> Self {
        guard let screenshotError = error as? BrowserScreenshotError else {
            return .failure(
                code: "internal_error",
                message: error.localizedDescription
            )
        }
        switch screenshotError {
        case .automationTimedOut:
            return .timedOut(message: screenshotError.localizedDescription)
        case .captureInProgress:
            return .failure(
                code: "timeout",
                message: screenshotError.localizedDescription
            )
        case .renderedContentMismatch:
            return .failure(
                code: "screenshot_mismatch",
                message: screenshotError.localizedDescription
            )
        case .captureAreaTooLarge,
             .emptySnapshot,
             .invalidSelection,
             .invalidImageRepresentation,
             .pasteboardWriteFailed,
             .webContentMetricsUnavailable:
            return .failure(
                code: "internal_error",
                message: screenshotError.localizedDescription
            )
        }
    }
}
