/// Why a simulator could not be attached.
public enum SimulatorCaptureError: Error, Hashable, Sendable {
    /// No booted simulator with that UDID.
    case notFound
    /// Capture or input injection is not available (permissions, Xcode missing).
    case unavailable(String)
}
