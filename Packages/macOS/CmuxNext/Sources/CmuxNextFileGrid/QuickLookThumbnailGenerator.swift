import AVFoundation
public import CoreGraphics
public import Foundation
import QuickLookThumbnailing

/// ``ThumbnailGenerating`` over the system: Quick Look draws stills and
/// movie poster frames (every format the Mac has a thumbnailer for,
/// including CleanShot X's and Snagit's extensions), AVFoundation reads a
/// movie's length.
public nonisolated struct QuickLookThumbnailGenerator: ThumbnailGenerating {
    /// Makes the system generator.
    public init() {}

    /// A Quick Look thumbnail (`.thumbnail` representation only: no icon fallback).
    ///
    /// - Parameters:
    ///   - url: the file.
    ///   - side: the tile's side in points.
    ///   - scale: the screen's backing scale.
    public func thumbnail(for url: URL, side: CGFloat, scale: CGFloat) async -> CGImage? {
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: side, height: side), scale: scale,
                                                   representationTypes: .thumbnail)
        return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).cgImage
    }

    /// The movie's duration from AVFoundation, nil when it has none.
    ///
    /// - Parameter url: the file.
    public func duration(for url: URL) async -> TimeInterval? {
        guard let time = try? await AVURLAsset(url: url).load(.duration), time.isNumeric else { return nil }
        let seconds = time.seconds
        return seconds.isFinite && seconds > 0 ? seconds : nil
    }
}
