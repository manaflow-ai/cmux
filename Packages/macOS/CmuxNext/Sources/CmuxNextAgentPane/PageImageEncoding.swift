package import AppKit

/// How a saved page image (`AgentPaneLaunchImages`, the next launch's first frame) is encoded.
/// An opaque page is a JPEG. A transparent page (the New Tab page, or a page over a background
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

    /// The file extension of its encoding: `png` with clear pixels, else `jpg`.
    package var pageImageExtension: String { keepsClearPixels ? "png" : "jpg" }

    /// The frame as a PNG when it keeps clear pixels, else as a JPEG.
    package func pageImageData() -> Data? {
        let rep = NSBitmapImageRep(cgImage: self)
        return keepsClearPixels ? rep.representation(using: .png, properties: [:])
            : rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8])
    }
}
