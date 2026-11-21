package import AppKit
import ImageIO

/// How a saved page image or terminal frame (`AgentPaneLaunchImages`, `TerminalLaunchFrames`: the next
/// launch's first frame) is encoded. An opaque page is a JPEG. A transparent page (the New Tab page, or a page over a background
/// image or a see-through window; `PageImageBackground`) is a PNG with its clear pixels kept, so
/// the window's backdrop shows through the first frame as it does through the live page. A JPEG
/// has no alpha: it painted those pixels a solid color over the art until the live page drew.
nonisolated extension CGImage {
    /// Whether the frame has clear pixels to keep: a flattened page (`PageImageBackground`) has none.
    package var keepsClearPixels: Bool {
        switch alphaInfo {
        case .none, .noneSkipLast, .noneSkipFirst: false
        default: true
        }
    }

    /// Whether the frame shows anything through it: it has alpha (``keepsClearPixels``) and a 32 x 32 sample of it
    /// has a pixel that is not opaque. A renderer's capture has alpha whether or not it drew a background (a terminal
    /// on an opaque window draws one; on a see-through window it draws none, so most of its pixels are clear).
    package var showsClearPixels: Bool {
        guard keepsClearPixels else { return false }
        let side = 32
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let pixels = context.data?.bindMemory(to: UInt8.self, capacity: side * side * 4) else { return true }
        context.draw(self, in: CGRect(x: 0, y: 0, width: side, height: side))
        return stride(from: 3, to: side * side * 4, by: 4).contains { pixels[$0] < 255 }
    }

    /// The file extension of its encoding: `png` with clear pixels, else `jpg`.
    package var pageImageExtension: String { keepsClearPixels ? "png" : "jpg" }

    /// The frame as a PNG when it keeps clear pixels, else as a JPEG.
    package func pageImageData() -> Data? { pageImageData(png: keepsClearPixels, jpegQuality: 0.8) }

    /// The frame as a PNG (its clear pixels kept) when `png`, else as a JPEG of `jpegQuality`.
    package func pageImageData(png: Bool, jpegQuality: Double) -> Data? {
        let rep = NSBitmapImageRep(cgImage: self)
        return png ? rep.representation(using: .png, properties: [:])
            : rep.representation(using: .jpeg, properties: [.compressionFactor: jpegQuality])
    }

    /// The frame as a PNG with no per-row filter (`IMAGEIO_PNG_FILTER_NONE`). For a terminal frame (flat runs of one
    /// color and text) it is cheaper on all three counts than the default adaptive filter (``pageImageData(png:jpegQuality:)``),
    /// measured on an M4 mini, 2800 x 1800 px see-through frame: encode 20.8 ms vs 26.1, 444 KiB vs 550, decode 6.0 ms
    /// vs 15.4 (the launch read decodes it). Lossless either way: the same pixels.
    package func unfilteredPNGData() -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        let properties = [kCGImagePropertyPNGDictionary: [kCGImagePropertyPNGCompressionFilter: IMAGEIO_PNG_FILTER_NONE]]
        CGImageDestinationAddImage(destination, self, properties as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
