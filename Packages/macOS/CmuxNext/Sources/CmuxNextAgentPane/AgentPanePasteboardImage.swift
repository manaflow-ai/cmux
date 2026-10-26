import AppKit
import CmuxNextCompat
import UniformTypeIdentifiers

/// An image file's bytes as a Copy or a drag out of an agent chat puts them on the pasteboard: the file's own
/// bytes and, for a type other than TIFF, a TIFF of its pixels for apps that read only TIFF. Both are made where the
/// bytes are read, off the main actor, so the pasteboard only hands them over: the main thread never decodes or
/// encodes the image (Chrome decodes images off its UI thread: services/data_decoder/public/cpp/decode_image.h).
nonisolated struct AgentPanePasteboardImage: Sendable, Equatable {
    /// The file's bytes.
    let data: Data
    /// A TIFF of the pixels; nil for a TIFF file (``data`` is one) or bytes that decode to no image.
    let tiff: Data?

    /// `data`, an image of `type`, with its TIFF made here, on the calling thread (call it off the main actor).
    ///
    /// - Parameters:
    ///   - data: The image's bytes.
    ///   - type: The image's type, from its file's extension.
    init(_ data: Data, type: UTType) {
        self.data = data
        tiff = type.conforms(to: .tiff) ? nil : Self.tiff(of: data)
    }

    /// A TIFF of `data`'s pixels: decoded with ImageIO, or through `NSImage` for what ImageIO does not read (an SVG,
    /// a PDF), in a checked call either way.
    ///
    /// - Parameter data: The image's bytes.
    /// - Returns: The TIFF, or nil when `data` is no image.
    static func tiff(of data: Data) -> Data? {
        if let image = blockingImageDecode(data) { return NSBitmapImageRep(cgImage: image).tiffRepresentation }
        return blockingNSImage(data) { $0.tiffRepresentation }
    }
}
