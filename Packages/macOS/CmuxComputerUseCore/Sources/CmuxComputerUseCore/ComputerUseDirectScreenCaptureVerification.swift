/// Result of a helper-owned direct ScreenCaptureKit verification attempt.
public enum ComputerUseDirectScreenCaptureVerification: Equatable, Sendable {
    case ready
    case notCapturable
    case unavailable
}
