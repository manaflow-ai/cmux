public import CoreFoundation
public import ImageIO

/// Opens an image file, like `CGImageSourceCreateWithURL`, as a checked blocking call
/// (``blockingCall(_:fileID:line:_:)``, Chrome's `base::ScopedBlockingCall`; Chrome decodes files on a
/// may-block worker, chrome/browser/image_decoder/image_decoder.cc): it opens the file. The source reads it
/// lazily, so count, read properties and decode through the `blockingImageSource...` seams below.
///
/// - Parameters:
///   - url: The image file.
///   - options: ImageIO source options, or nil.
///   - fileID: The calling code's `#fileID` (names the call site).
///   - line: The calling code's `#line`.
/// - Returns: The source, or nil when the file cannot be read.
@inlinable
public func blockingImageSource(url: CFURL, options: CFDictionary? = nil,
                                fileID: StaticString = #fileID, line: UInt = #line) -> CGImageSource? {
    return blockingCall(.fileIO, fileID: fileID, line: line) { CGImageSourceCreateWithURL(url, options) }
}

/// Counts a source's images, like `CGImageSourceGetCount`, as a checked blocking call (kind
/// ``BlockingKind/fileIO``): a file-backed source reads the file to find them.
///
/// - Parameters:
///   - source: The source.
///   - fileID: The calling code's `#fileID` (names the call site).
///   - line: The calling code's `#line`.
/// - Returns: How many images the source holds.
@inlinable
public func blockingImageSourceCount(_ source: CGImageSource, fileID: StaticString = #fileID, line: UInt = #line) -> Int {
    return blockingCall(.fileIO, fileID: fileID, line: line) { CGImageSourceGetCount(source) }
}

/// Reads an image's properties, like `CGImageSourceCopyPropertiesAtIndex`, as a checked blocking call (kind
/// ``BlockingKind/fileIO``): a file-backed source reads the image's metadata from the file.
///
/// - Parameters:
///   - source: The source.
///   - index: The image.
///   - options: ImageIO options, or nil.
///   - fileID: The calling code's `#fileID` (names the call site).
///   - line: The calling code's `#line`.
/// - Returns: The properties, or nil when the image cannot be read.
@inlinable
public func blockingImageSourceCopyProperties(_ source: CGImageSource, at index: Int, options: CFDictionary? = nil,
                                              fileID: StaticString = #fileID, line: UInt = #line) -> CFDictionary? {
    return blockingCall(.fileIO, fileID: fileID, line: line) { CGImageSourceCopyPropertiesAtIndex(source, index, options) }
}

/// Decodes an image, like `CGImageSourceCreateImageAtIndex`, as a checked blocking call (kind
/// ``BlockingKind/fileIO``). Pass `kCGImageSourceShouldCacheImmediately` so the decode happens here, not on draw.
///
/// - Parameters:
///   - source: The source.
///   - index: The image.
///   - options: ImageIO options, or nil.
///   - fileID: The calling code's `#fileID` (names the call site).
///   - line: The calling code's `#line`.
/// - Returns: The image, or nil when it cannot be decoded.
@inlinable
public func blockingImageSourceCreateImage(_ source: CGImageSource, at index: Int, options: CFDictionary? = nil,
                                           fileID: StaticString = #fileID, line: UInt = #line) -> CGImage? {
    return blockingCall(.fileIO, fileID: fileID, line: line) { CGImageSourceCreateImageAtIndex(source, index, options) }
}

/// Decodes a thumbnail, like `CGImageSourceCreateThumbnailAtIndex`, as a checked blocking call (kind
/// ``BlockingKind/fileIO``): it reads and scales the image, or reads its embedded thumbnail.
///
/// - Parameters:
///   - source: The source.
///   - index: The image.
///   - options: ImageIO thumbnail options (`kCGImageSourceThumbnailMaxPixelSize`), or nil.
///   - fileID: The calling code's `#fileID` (names the call site).
///   - line: The calling code's `#line`.
/// - Returns: The thumbnail, or nil when it cannot be made.
@inlinable
public func blockingImageSourceCreateThumbnail(_ source: CGImageSource, at index: Int, options: CFDictionary? = nil,
                                               fileID: StaticString = #fileID, line: UInt = #line) -> CGImage? {
    return blockingCall(.fileIO, fileID: fileID, line: line) { CGImageSourceCreateThumbnailAtIndex(source, index, options) }
}

/// Makes an image writer for a file, like `CGImageDestinationCreateWithURL`, as a checked blocking call
/// (``blockingCall(_:fileID:line:_:)``): it creates the file.
///
/// - Parameters:
///   - url: The file to write.
///   - type: The image's uniform type identifier (`UTType.png.identifier as CFString`).
///   - count: How many images the file holds.
///   - fileID: The calling code's `#fileID` (names the call site).
///   - line: The calling code's `#line`.
/// - Returns: The destination, or nil when the file cannot be created.
@inlinable
public func blockingImageDestination(url: CFURL, type: CFString, count: Int,
                                     fileID: StaticString = #fileID, line: UInt = #line) -> CGImageDestination? {
    return blockingCall(.fileIO, fileID: fileID, line: line) { CGImageDestinationCreateWithURL(url, type, count, nil) }
}

/// Encodes and writes the images, like `CGImageDestinationFinalize`, as a checked blocking call
/// (``blockingCall(_:fileID:line:_:)``): it compresses every image and writes the file.
///
/// - Parameters:
///   - destination: The destination.
///   - fileID: The calling code's `#fileID` (names the call site).
///   - line: The calling code's `#line`.
/// - Returns: Whether the file was written.
@inlinable
public func blockingImageDestinationFinalize(_ destination: CGImageDestination,
                                             fileID: StaticString = #fileID, line: UInt = #line) -> Bool {
    return blockingCall(.fileIO, fileID: fileID, line: line) { CGImageDestinationFinalize(destination) }
}
