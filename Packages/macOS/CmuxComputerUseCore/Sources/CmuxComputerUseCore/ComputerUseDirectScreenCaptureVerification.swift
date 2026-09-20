/// Result of a helper-owned direct ScreenCaptureKit verification attempt.
public enum ComputerUseDirectScreenCaptureVerification: Equatable, Sendable {
    /// The helper captured successfully.
    case ready
    /// The helper is running but capture is not currently permitted.
    case notCapturable
    /// The helper or its authenticated socket was unavailable.
    case unavailable
}
