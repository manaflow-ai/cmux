public import AppKit
public import CmuxNextCompat
public import Foundation
public import ImageIO

/// Makes an image of encoded image data, like `NSImage(data:)`, as a checked CPU call
/// (``cpuIntensiveCall(size:limit:fileID:line:_:)``) gated like ``blockingImageDecode(_:at:fileID:line:)``: on the
/// main thread, data whose header says more than ``BlockingKind/cpuIntensiveImagePixelBytes`` bytes of pixels (or,
/// for what ImageIO does not read, an SVG or a PDF, more than that many bytes of data) is a
/// ``BlockingKind/cpuIntensive`` site.
///
/// `NSImage` parses the container here (all of an SVG or a PDF); a bitmap's pixels decode at its first draw, on the
/// thread that draws it, outside this check. So use it for what only `NSImage` reads (SVG, PDF, ICNS, a multi-size
/// ICO) and for small images. For a bitmap, decode with ``blockingImageDecode(_:at:fileID:line:)`` off the main
/// thread and wrap the result with `NSImage(cgImage:size:)`; to draw the image in the same call (a redraw, an
/// encode), use ``blockingNSImage(_:fileID:line:render:)``. Read a file first with
/// ``Foundation/Data/init(blockingContentsOf:options:fileID:line:)``, where `NSImage(contentsOf:)` would read it
/// unchecked.
///
/// - Parameters:
///   - data: The encoded image.
///   - fileID: The calling code's `#fileID` (names the call site).
///   - line: The calling code's `#line`.
/// - Returns: The image, or nil when `data` is not one `NSImage` reads.
@inlinable
public func blockingNSImage(_ data: Data, fileID: StaticString = #fileID, line: UInt = #line) -> NSImage? {
    blockingNSImage(data, fileID: fileID, line: line) { $0 }
}

/// Makes an image of encoded image data, like `NSImage(data:)`, and runs `render` on it in the same checked CPU call,
/// gated like ``blockingNSImage(_:fileID:line:)``. `render` is the work that decodes the pixels (a redraw into a
/// bitmap context, an encode), so the check times the whole decode, not only the container parse.
///
/// - Parameters:
///   - data: The encoded image.
///   - fileID: The calling code's `#fileID` (names the call site).
///   - line: The calling code's `#line`.
///   - render: What to make of the image; nil drops it.
/// - Returns: What `render` returns, or nil when `data` is not one `NSImage` reads.
@inlinable
public func blockingNSImage<Result>(
    _ data: Data, fileID: StaticString = #fileID, line: UInt = #line, render: (NSImage) -> Result?
) -> Result? {
    cpuIntensiveCall(
        size: encodedImagePixelBytes(data), limit: BlockingKind.cpuIntensiveImagePixelBytes, fileID: fileID, line: line
    ) { () -> Result? in
        NSImage(data: data).flatMap(render)
    }
}

/// The bytes the first image of `data` decodes to, 4 per pixel, from its header (no pixel is decoded), or
/// `data.count` when that is larger or ImageIO reads no size (an SVG, a PDF).
///
/// - Parameter data: The encoded image.
/// - Returns: The larger of the decoded and the encoded size.
@usableFromInline
func encodedImagePixelBytes(_ data: Data) -> Int {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return data.count }
    return decodedImageBytes(source, at: 0, encoded: data.count)
}
