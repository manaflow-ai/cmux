#if DEBUG
import Foundation

/// Describes the bounded result of a ScreenCaptureKit screenshot attempt.
enum WindowScreenshotCaptureAttempt: Sendable {
    case captured(Data)
    case unavailable
    case timedOut
}
#endif
