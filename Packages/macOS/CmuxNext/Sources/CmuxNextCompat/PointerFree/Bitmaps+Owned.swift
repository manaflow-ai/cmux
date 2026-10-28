public import AppKit
public import CoreGraphics

// Image and bitmap calls whose C signature takes a pointer the callers always pass as nil, each
// written once with its `unsafe` and SAFETY argument so the callers stay pointer-free (strict
// memory safety): the way Chromium keeps each UNSAFE_BUFFERS() in one helper
// instead of at every use (docs/unsafe_buffers.md).

extension NSImage {
    /// The Core Graphics image AppKit picks for the image at its own size
    /// (`cgImage(forProposedRect:context:hints:)` with no proposed rect, context or hints).
    public var bestCGImage: CGImage? {
        // SAFETY: the proposed-rect pointer is nil, so AppKit reads and writes no caller memory and
        // uses the image's own size.
        unsafe cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}

extension NSBitmapImageRep {
    /// An 8-bit RGBA bitmap in device RGB whose pixels AppKit allocates and owns.
    ///
    /// - Parameters:
    ///   - width: Pixels across.
    ///   - height: Pixels down.
    /// - Returns: The bitmap, or nil when AppKit refuses the size.
    public static func ownedRGBA(width: Int, height: Int) -> NSBitmapImageRep? {
        // SAFETY: the planes pointer is nil, so AppKit allocates and owns the pixel buffer, sized from
        // the dimensions and the row bytes it picks (bytesPerRow 0); nothing is read or written
        // through a pointer passed from here.
        unsafe NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                bytesPerRow: 0, bitsPerPixel: 0)
    }
}

extension CGContext {
    /// An 8-bit-per-component bitmap context whose pixels Core Graphics allocates, owns and frees
    /// with the context; callers read it back through `makeImage()`, so no Swift pointer to the
    /// pixels exists.
    ///
    /// - Parameters:
    ///   - width: Pixels across.
    ///   - height: Pixels down.
    ///   - bytesPerRow: The row size; 0 lets Core Graphics pick it.
    ///   - space: The color space.
    ///   - bitmapInfo: The alpha and byte-order layout (`CGImageAlphaInfo` and `CGBitmapInfo` bits).
    /// - Returns: The context, or nil when Core Graphics refuses the size or format.
    public static func bitmapOwningPixels(width: Int, height: Int, bytesPerRow: Int = 0, space: CGColorSpace,
                                          bitmapInfo: UInt32) -> CGContext? {
        // SAFETY: `data` is nil, so Core Graphics allocates a buffer sized from the width, height and
        // row bytes and frees it with the context; nothing is read or written through a pointer
        // passed from here.
        unsafe CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                         space: space, bitmapInfo: bitmapInfo)
    }
}
