public import CoreGraphics
public import Foundation
public import ImageIO

/// Encoded image data (PNG, JPEG, HEIC, GIF...) opened with ImageIO, whose decodes are checked CPU calls gated like
/// ``blockingImageDecode(_:at:fileID:line:)``, by decoded pixels: on the main thread, an image or thumbnail of an
/// image whose header says more than ``BlockingKind/cpuIntensiveImagePixelBytes`` bytes of pixels (4 a pixel) is a
/// ``BlockingKind/cpuIntensive`` site, however small the data is. Reading the type, the image count and the
/// properties parses only the header, so it is unchecked.
///
/// It is the seam for code that needs the `CGImageSource` itself (a type check, a pixel-size limit, a frame of a
/// dynamic HEIC); ``blockingImageDecode(_:at:fileID:line:)`` and ``blockingImageThumbnail(_:at:options:fileID:line:)``
/// cover a plain decode. Chrome decodes images off its UI thread in the same way (`ImageDecoder`,
/// services/data_decoder/public/cpp/decode_image.h).
public struct CheckedImageSource {
    /// The ImageIO source, for reading its header (a frame lookup in a dynamic HEIC). Decode through
    /// ``image(at:options:fileID:line:)`` or ``thumbnail(at:options:fileID:line:)``, never with it directly.
    public let source: CGImageSource
    /// The encoded size; a decode's gate counts the larger of it and the image's decoded pixels.
    public let byteCount: Int

    /// Opens `data`, like `CGImageSourceCreateWithData`; nil when ImageIO cannot make a source of it.
    ///
    /// - Parameters:
    ///   - data: The encoded image.
    ///   - options: ImageIO's source options (`kCGImageSourceShouldCache`, `kCGImageSourceTypeIdentifierHint`).
    public init?(_ data: Data, options: [CFString: Any]? = nil) {
        let sourceOptions = options.map { $0 as CFDictionary }
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        self.source = source
        byteCount = data.count
    }

    /// Opens the image file at `url`: it maps the file through
    /// ``Foundation/Data/init(blockingContentsOf:options:fileID:line:)`` (a checked file read, so open files off
    /// the main thread), where `CGImageSourceCreateWithURL` would read it unchecked. Nil when the file cannot be
    /// read or holds nothing ImageIO opens.
    ///
    /// - Parameters:
    ///   - url: The image file.
    ///   - options: ImageIO's source options.
    ///   - fileID: The calling code's `#fileID` (names the call site).
    ///   - line: The calling code's `#line`.
    public init?(
        blockingContentsOf url: URL, options: [CFString: Any]? = nil, fileID: StaticString = #fileID, line: UInt = #line
    ) {
        guard let data = try? Data(blockingContentsOf: url, options: .mappedIfSafe, fileID: fileID, line: line) else {
            return nil
        }
        self.init(data, options: options)
    }

    /// The uniform type identifier of the data (`public.png`), like `CGImageSourceGetType`.
    public var type: String? { CGImageSourceGetType(source) as String? }

    /// How many images the data holds, like `CGImageSourceGetCount`.
    public var count: Int { CGImageSourceGetCount(source) }

    /// The properties of the image at `index` (pixel size, orientation), like `CGImageSourceCopyPropertiesAtIndex`.
    ///
    /// - Parameters:
    ///   - index: Which image.
    ///   - options: ImageIO's options (`kCGImageSourceShouldCache`).
    /// - Returns: The properties, or nil when there is no image at `index`.
    public func properties(at index: Int = 0, options: [CFString: Any]? = nil) -> [CFString: Any]? {
        CGImageSourceCopyPropertiesAtIndex(source, index, options.map { $0 as CFDictionary }) as? [CFString: Any]
    }

    /// Decodes the image at `index`, like `CGImageSourceCreateImageAtIndex`, as a checked CPU call. The pixels are
    /// decoded here (`kCGImageSourceShouldCacheImmediately`), on the calling thread, so the gate times the decode.
    ///
    /// A caller that passes `kCGImageSourceShouldCache: false` gets a lazy image: only its header is read here, and
    /// its pixels decode at each draw, on the drawing thread, unchecked. Use that only for an image that is checked
    /// and then dropped, or drawn off the main thread.
    ///
    /// - Parameters:
    ///   - index: Which image.
    ///   - options: ImageIO's decode options.
    ///   - fileID: The calling code's `#fileID` (names the call site).
    ///   - line: The calling code's `#line`.
    /// - Returns: The image, or nil when there is none at `index`.
    @inlinable
    public func image(
        at index: Int = 0, options: [CFString: Any]? = nil, fileID: StaticString = #fileID, line: UInt = #line
    ) -> CGImage? {
        if (options?[kCGImageSourceShouldCache] as? Bool) == false {
            return CGImageSourceCreateImageAtIndex(source, index, options.map { $0 as CFDictionary })
        }
        let decodeNow = (options ?? [:]).merging([kCGImageSourceShouldCacheImmediately: true]) { _, now in now }
        return cpuIntensiveCall(
            size: decodedImageBytes(source, at: index, encoded: byteCount),
            limit: BlockingKind.cpuIntensiveImagePixelBytes, fileID: fileID, line: line
        ) { () -> CGImage? in
            CGImageSourceCreateImageAtIndex(source, index, decodeNow as CFDictionary)
        }
    }

    /// Makes a thumbnail of the image at `index`, like `CGImageSourceCreateThumbnailAtIndex`, as a checked CPU call
    /// gated by the full image's decoded pixels (the thumbnail decodes the source to scale it).
    ///
    /// - Parameters:
    ///   - index: Which image.
    ///   - options: ImageIO's thumbnail options (`kCGImageSourceThumbnailMaxPixelSize`,
    ///     `kCGImageSourceCreateThumbnailFromImageAlways`, ...).
    ///   - fileID: The calling code's `#fileID` (names the call site).
    ///   - line: The calling code's `#line`.
    /// - Returns: The thumbnail, or nil when there is no image at `index`.
    @inlinable
    public func thumbnail(
        at index: Int = 0, options: [CFString: Any], fileID: StaticString = #fileID, line: UInt = #line
    ) -> CGImage? {
        cpuIntensiveCall(
            size: decodedImageBytes(source, at: index, encoded: byteCount),
            limit: BlockingKind.cpuIntensiveImagePixelBytes, fileID: fileID, line: line
        ) { () -> CGImage? in
            CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary)
        }
    }
}
