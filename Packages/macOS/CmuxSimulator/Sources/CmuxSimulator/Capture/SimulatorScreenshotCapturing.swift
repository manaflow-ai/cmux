public import Foundation

/// Captures one still image of a simulator device's display.
///
/// The single-capture seam under ``SimctlScreenshotCaptureBackend``: the
/// backend owns pacing and deduplication, this protocol owns how one frame is
/// obtained. Production uses ``SimctlFileScreenshotSource``; tests inject a
/// fake that returns canned bytes.
public protocol SimulatorScreenshotCapturing: Sendable {
    /// Captures the device's current display contents as encoded image data.
    ///
    /// - Parameter udid: The device to capture.
    /// - Returns: The encoded image bytes (PNG).
    /// - Throws: When the capture fails (e.g. the device is not booted yet).
    func captureScreenshot(of udid: SimulatorDeviceUDID) async throws -> Data
}
