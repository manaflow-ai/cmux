internal import Foundation

/// The v1 fallback capture backend: periodic `simctl` screenshot captures.
///
/// Public API only (no private frameworks, no Screen Recording permission, no
/// Simulator.app requirement — headless-booted devices render too), at the
/// cost of frame rate: each frame is one full screenshot round-trip (about a
/// second on current hardware), so the effective rate is roughly 1 fps.
/// Captures that fail (e.g. while the device is still booting) are skipped
/// silently and capture resumes on the next tick; unchanged captures are
/// dropped by ``SimulatorFrameDeduplicator``.
public struct SimctlScreenshotCaptureBackend: SimulatorDisplayCapturing {
    private let source: any SimulatorScreenshotCapturing
    private let frameInterval: Duration

    /// Creates a screenshot-streaming backend over a single-capture source.
    ///
    /// - Parameters:
    ///   - source: The single-capture seam.
    ///   - frameInterval: The pause between captures. Defaults to 250 ms;
    ///     with capture time included the effective rate is ~1 fps.
    public init(
        source: any SimulatorScreenshotCapturing,
        frameInterval: Duration = .milliseconds(250)
    ) {
        self.source = source
        self.frameInterval = frameInterval
    }

    /// Creates a screenshot-streaming backend over the file-based `simctl`
    /// screenshot source.
    ///
    /// - Parameters:
    ///   - runner: The `simctl` seam.
    ///   - frameInterval: The pause between captures. Defaults to 250 ms.
    public init(
        runner: any SimctlCommandRunning,
        frameInterval: Duration = .milliseconds(250)
    ) {
        self.init(
            source: SimctlFileScreenshotSource(runner: runner),
            frameInterval: frameInterval
        )
    }

    /// Streams display frames by polling the screenshot source.
    ///
    /// - Parameter udid: The device whose display to capture.
    /// - Returns: A stream that finishes when the consumer cancels.
    public func frames(for udid: SimulatorDeviceUDID) -> AsyncStream<SimulatorDisplayFrame> {
        let source = source
        let frameInterval = frameInterval
        return AsyncStream { continuation in
            let captureTask = Task {
                var deduplicator = SimulatorFrameDeduplicator()
                while !Task.isCancelled {
                    if let capture = try? await source.captureScreenshot(of: udid),
                       let frame = deduplicator.frame(for: capture) {
                        continuation.yield(frame)
                    }
                    // Screenshot streaming is periodic by design: this backend's
                    // contract is one capture per interval, so the bounded,
                    // cancellable sleep IS the intended pacing (not a poll for a
                    // condition a callback could deliver). Push-driven backends
                    // conforming to SimulatorDisplayCapturing replace it.
                    do {
                        try await Task.sleep(for: frameInterval)
                    } catch {
                        break
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                captureTask.cancel()
            }
        }
    }
}
