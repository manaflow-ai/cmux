/// A source of live display frames for one simulator device.
///
/// The capture backend is a protocol seam so the pane can swap
/// implementations: the shipped ``SimctlScreenshotCaptureBackend`` streams
/// periodic `simctl io screenshot` captures, and richer backends (a
/// CoreSimulator framebuffer service, or ScreenCaptureKit against a
/// Simulator.app window) can conform later without touching the pane.
public protocol SimulatorDisplayCapturing: Sendable {
    /// Streams display frames for a device until the consumer cancels.
    ///
    /// The stream finishes when the consuming task is cancelled; backends
    /// stop all capture work on termination.
    ///
    /// - Parameter udid: The device whose display to capture.
    /// - Returns: An unbounded-latency stream of deduplicated frames.
    func frames(for udid: SimulatorDeviceUDID) -> AsyncStream<SimulatorDisplayFrame>
}
