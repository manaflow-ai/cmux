internal import Foundation

/// The v1 fallback capture backend: periodic `simctl io screenshot` PNGs.
///
/// Public API only (no private frameworks, no Screen Recording permission, no
/// Simulator.app requirement — headless-booted devices render too), at the
/// cost of frame rate: each frame is one full screenshot round-trip, so the
/// effective rate is a few frames per second. Captures that fail (e.g. while
/// the device is still booting) are skipped silently and capture resumes on
/// the next tick; unchanged captures are dropped by
/// ``SimulatorFrameDeduplicator``.
public struct SimctlScreenshotCaptureBackend: SimulatorDisplayCapturing {
    private let runner: any SimctlCommandRunning
    private let frameInterval: Duration

    /// Creates a screenshot-streaming backend.
    ///
    /// - Parameters:
    ///   - runner: The `simctl` seam.
    ///   - frameInterval: The pause between captures. Defaults to 250 ms,
    ///     which lands around 2–3 fps once capture time is included.
    public init(
        runner: any SimctlCommandRunning,
        frameInterval: Duration = .milliseconds(250)
    ) {
        self.runner = runner
        self.frameInterval = frameInterval
    }

    /// Streams display frames by polling `simctl io <udid> screenshot`.
    ///
    /// - Parameter udid: The device whose display to capture.
    /// - Returns: A stream that finishes when the consumer cancels.
    public func frames(for udid: SimulatorDeviceUDID) -> AsyncStream<SimulatorDisplayFrame> {
        let runner = runner
        let frameInterval = frameInterval
        return AsyncStream { continuation in
            let captureTask = Task {
                var deduplicator = SimulatorFrameDeduplicator()
                while !Task.isCancelled {
                    if let capture = try? await runner.run(
                        ["io", udid.rawValue, "screenshot", "--type=png", "-"]
                    ), let frame = deduplicator.frame(for: capture) {
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
