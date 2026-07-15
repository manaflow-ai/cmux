public import CoreGraphics
internal import Foundation
internal import ImageIO

/// One display frame decoded to a render-ready bitmap.
///
/// Decoding happens where the frame is produced (off the main actor), so the
/// pane view never runs ImageIO on the main thread — rendering an encoded
/// `NSImage`/PNG from SwiftUI re-decodes on main during display-list updates,
/// which starves the main actor while frames stream (the original v1 bug).
public struct SimulatorRenderedFrame: @unchecked Sendable {
    // @unchecked Sendable: CGImage is immutable after creation and documented
    // thread-safe to read from any thread; all other members are value types.

    /// The fully decoded bitmap.
    public let image: CGImage
    /// A monotonically increasing frame number within one capture stream.
    public let sequence: Int

    /// Creates a rendered frame from an already-decoded bitmap.
    ///
    /// - Parameters:
    ///   - image: The decoded bitmap.
    ///   - sequence: The frame's position within its stream.
    public init(image: CGImage, sequence: Int) {
        self.image = image
        self.sequence = sequence
    }

    /// Decodes an encoded capture into a rendered frame, forcing the full
    /// bitmap decode now (not lazily at first draw).
    ///
    /// - Parameter frame: The encoded capture.
    /// - Returns: The decoded frame, or `nil` when the data is not an image.
    public init?(decoding frame: SimulatorDisplayFrame) {
        let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        guard let source = CGImageSourceCreateWithData(frame.imageData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, options) else {
            return nil
        }
        self.image = image
        self.sequence = frame.sequence
    }
}
