import CoreGraphics
import Foundation
import ImageIO

/// An upload's frames as the pet plays them: a GIF's frames with their own delays, or one still.
nonisolated struct ChiefPetClip: Sendable {
    /// The most frames kept (at most 256 x 256 px each, about 16 MB in all).
    static let maximumFrames = 64
    let frames: [CGImage]
    /// Seconds each frame shows.
    let delays: [TimeInterval]

    /// The frames of `file` (read off the main actor); nil when it cannot be read.
    init?(file: URL) {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil) else { return nil }
        let count = min(CGImageSourceGetCount(source), Self.maximumFrames)
        // A moving GIF's frames are at most 256 px; a still is the 512 px PNG the upload made.
        let largest = count > 1 ? ChiefAvatarUploads.maximumGIFPixels : ChiefAvatarUploads.stillSide
        var frames: [CGImage] = [], delays: [TimeInterval] = []
        for index in 0..<count {
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            // A frame past the GIF limit is never decoded (the upload checked them; this file could have changed).
            guard let width = properties?[kCGImagePropertyPixelWidth] as? Int, let height = properties?[kCGImagePropertyPixelHeight] as? Int,
                  max(width, height) <= largest,
                  let frame = CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }
            let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let delay = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double) ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0
            frames.append(frame)
            // A delay under 20 ms plays at 100 ms, as browsers play it.
            delays.append(delay < 0.02 ? 0.1 : delay)
        }
        guard !frames.isEmpty else { return nil }
        self.frames = frames
        self.delays = delays
    }
}
