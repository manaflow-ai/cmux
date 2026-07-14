public import Foundation

/// Drops consecutive identical captures and stamps sequence numbers.
///
/// `simctl` screenshots are deterministic for an unchanged framebuffer, so an
/// idle device produces byte-identical captures; skipping them keeps the pane
/// from re-decoding and re-rendering an unchanged image every interval.
public struct SimulatorFrameDeduplicator: Sendable {
    private var lastImageData: Data?
    private var sequence = 0

    /// Creates a deduplicator with no frames seen.
    public init() {}

    /// Wraps a capture in a frame, or returns `nil` for an empty or
    /// unchanged capture.
    ///
    /// - Parameter imageData: The encoded image bytes of one capture.
    /// - Returns: The next frame, or `nil` when the capture should be dropped.
    public mutating func frame(for imageData: Data) -> SimulatorDisplayFrame? {
        guard !imageData.isEmpty, imageData != lastImageData else { return nil }
        lastImageData = imageData
        sequence += 1
        return SimulatorDisplayFrame(imageData: imageData, sequence: sequence)
    }
}
