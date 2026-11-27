public import CoreGraphics
public import Foundation

/// Makes the picture and the movie length a grid tile shows. The seam
/// ``ThumbnailCache`` renders through, so tests count renders without
/// Quick Look.
public nonisolated protocol ThumbnailGenerating: Sendable {
    /// A thumbnail of the file at `url` that fits a `side`-point square at `scale`, nil when the
    /// system cannot draw one.
    ///
    /// - Parameters:
    ///   - url: the file.
    ///   - side: the tile's side in points.
    ///   - scale: the screen's backing scale.
    func thumbnail(for url: URL, side: CGFloat, scale: CGFloat) async -> CGImage?

    /// The length of the movie at `url` in seconds, nil for a still or an unreadable file.
    ///
    /// - Parameter url: the file.
    func duration(for url: URL) async -> TimeInterval?
}
