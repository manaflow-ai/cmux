// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import Foundation
import ImageIO

/// Decoding and encoding of the screenshots in tool results.
struct PerceptionImage: Sendable {
    static func decode(base64: String) -> CGImage? {
        guard let data = Data(base64Encoded: base64),
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// JPEG at `quality` (0...1). Text stays legible at 0.85; the model's
    /// token cost depends only on the pixel size, so this changes bytes only.
    static func jpeg(_ image: CGImage, quality: Double = 0.85) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image,
                                   [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// The image's pixels inside `rect` (top-left origin).
    static func crop(_ image: CGImage, to rect: PixelRect) -> CGImage? {
        image.cropping(to: CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height))
    }

    /// Anthropic's estimate of an image's input tokens: width x height / 750.
    static func estimatedTokens(width: Int, height: Int) -> Int { (width * height + 749) / 750 }
}
