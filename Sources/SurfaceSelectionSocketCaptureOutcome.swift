import Foundation

/// Sendable boundary between main-actor panel capture and worker-lane encoding.
nonisolated enum SurfaceSelectionSocketCaptureOutcome: Sendable {
    case captured(SurfaceSelectionSocketCapture)
    case failed(SurfaceSelectionSocketFailure)
}
