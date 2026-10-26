public import AppKit

/// Makes an image of encoded image data, like `NSImage(data:)`, as a checked CPU call
/// (``cpuIntensiveCall(size:limit:fileID:line:_:)``): on the main thread, `data` larger than
/// ``BlockingKind/cpuIntensiveImageBytes`` is a ``BlockingKind/cpuIntensive`` site.
///
/// `NSImage` parses the container here (all of an SVG or a PDF); a bitmap's pixels decode at its first draw, on the
/// thread that draws it. When the pixels should decode now, off the main thread, use
/// ``blockingImageDecode(_:at:fileID:line:)`` and wrap the result with `NSImage(cgImage:size:)`. Use this one for
/// what only `NSImage` reads (SVG, PDF, ICNS) and for small images. A file is read first with
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
    cpuIntensiveCall(size: data.count, limit: BlockingKind.cpuIntensiveImageBytes, fileID: fileID, line: line) {
        NSImage(data: data)
    }
}
