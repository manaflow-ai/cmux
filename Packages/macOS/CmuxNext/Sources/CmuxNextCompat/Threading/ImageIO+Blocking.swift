public import CoreFoundation
public import ImageIO

/// Opens an image file, like `CGImageSourceCreateWithURL`, as a checked blocking call
/// (``blockingCall(_:fileID:line:_:)``, Chrome's `base::ScopedBlockingCall`; Chrome decodes files on a
/// may-block worker, chrome/browser/image_decoder/image_decoder.cc): it opens and reads the file's header.
/// Decoding later reads the rest, so decode on the same off-main thread.
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
