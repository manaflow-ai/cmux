public import Foundation

/// One captured image of a simulator device's display.
public struct SimulatorDisplayFrame: Hashable, Sendable {
    /// The encoded image bytes (PNG for the `simctl` screenshot backend).
    public let imageData: Data
    /// A monotonically increasing frame number within one capture stream.
    public let sequence: Int

    /// Creates a frame.
    ///
    /// - Parameters:
    ///   - imageData: The encoded image bytes.
    ///   - sequence: The frame's position within its stream, starting at 1.
    public init(imageData: Data, sequence: Int) {
        self.imageData = imageData
        self.sequence = sequence
    }
}
