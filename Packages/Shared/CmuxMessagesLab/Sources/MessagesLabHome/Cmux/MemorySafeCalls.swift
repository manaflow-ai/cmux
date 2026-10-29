// cmux: the Core Graphics, Core Text and AppKit calls the transcript makes with a pointer it does not use (a nil
// transform, out-parameter or pixel buffer) or with an array the call reads as a pointer, and the array storage
// test, each wrapped once with its SAFETY argument (strict memory safety). Chromium does the
// same: one checked wrapper in base/ instead of an UNSAFE_BUFFERS() at every call site (docs/unsafe_buffers.md).
// Not a vendored file.
import AppKit
import CoreGraphics
import CoreText

extension Array {
    /// Whether this array and `other` share one buffer (one was copied from the other and neither written since), so
    /// their elements are the same values: an O(1) test where comparing every element costs a pass.
    func sharesStorage(with other: [Element]) -> Bool {
        // SAFETY: the two base addresses leave their closures only to be compared, never dereferenced or kept.
        unsafe withUnsafeBufferPointer({ unsafe $0.baseAddress }) == other.withUnsafeBufferPointer({ unsafe $0.baseAddress })
    }
}

extension UnsafeMutableBufferPointer {
    /// Writes `value` at `index` when it is inside the buffer, else logs a fault once per call site and writes nothing
    /// (`checkedIndex`'s rule). Nonmutating: the element changes, the buffer value does not, so threads writing distinct
    /// elements of one buffer share no write.
    func checkedWrite(_ value: Element, at index: Int, fileID: StaticString = #fileID, line: UInt = #line) {
        // SAFETY: the caller lends a live buffer for the call (its own SAFETY argument); the write happens only for
        // 0 <= index < count, inside it.
        guard unsafe index >= 0 && index < count else {
            CrashGuard.fault("write at \(index) outside the buffer", fileID: fileID, line: line)
            return
        }
        unsafe self[index] = value
    }
}

extension CGPath {
    /// `CGPath(roundedRect:cornerWidth:cornerHeight:transform: nil)`.
    static func roundedRect(_ rect: CGRect, cornerWidth: CGFloat, cornerHeight: CGFloat) -> CGPath {
        // SAFETY: the transform pointer is nil, so Core Graphics reads no memory through it.
        unsafe CGPath(roundedRect: rect, cornerWidth: cornerWidth, cornerHeight: cornerHeight, transform: nil)
    }

    /// `CGPath(rect:transform: nil)`.
    static func rect(_ rect: CGRect) -> CGPath {
        // SAFETY: the transform pointer is nil, so Core Graphics reads no memory through it.
        unsafe CGPath(rect: rect, transform: nil)
    }

    /// `CGPath(ellipseIn:transform: nil)`.
    static func ellipse(in rect: CGRect) -> CGPath {
        // SAFETY: the transform pointer is nil, so Core Graphics reads no memory through it.
        unsafe CGPath(ellipseIn: rect, transform: nil)
    }

    /// `copy(using: &transform)`: this path moved by `transform`, or nil when Core Graphics makes none.
    func copy(applying transform: CGAffineTransform) -> CGPath? {
        var transform = transform
        // SAFETY: the pointer is to the local `transform`, lent for the call only; Core Graphics reads it during
        // the call and keeps no reference.
        return unsafe copy(using: &transform)
    }
}

extension CTLine {
    /// The typographic width (`CTLineGetTypographicBounds` without its out-parameters).
    var typographicWidth: Double {
        // SAFETY: the three out-pointers are nil, which Core Text documents as "not wanted"; nothing is written.
        unsafe CTLineGetTypographicBounds(self, nil, nil, nil)
    }

    /// The typographic width with the ascent, descent and leading (`CTLineGetTypographicBounds`).
    var typographicBounds: (width: Double, ascent: CGFloat, descent: CGFloat, leading: CGFloat) {
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        // SAFETY: each out-pointer is a local CGFloat lent for the call only; Core Text writes one value to each.
        let width = unsafe CTLineGetTypographicBounds(self, &ascent, &descent, &leading)
        return (width, ascent, descent, leading)
    }

    /// The primary graphical offset of string index `index` (`CTLineGetOffsetForStringIndex` without the
    /// secondary offset out-parameter).
    func offset(forStringIndex index: CFIndex) -> CGFloat {
        // SAFETY: the secondary-offset pointer is nil, which Core Text documents as "not wanted"; nothing is written.
        unsafe CTLineGetOffsetForStringIndex(self, index, nil)
    }
}

extension CGContext {
    /// A bitmap context that allocates, owns and frees its own pixels (`CGContext(data: nil, ...)`); nil when
    /// Core Graphics cannot make it.
    static func ownedBitmap(width: Int, height: Int, bitsPerComponent: Int, bytesPerRow: Int, space: CGColorSpace,
                            bitmapInfo: UInt32) -> CGContext? {
        // SAFETY: the data pointer is nil, so Core Graphics allocates the pixels (bytesPerRow 0: a row size it
        // picks), owns them and frees them with the context; no memory of the caller is read or written.
        unsafe CGContext(data: nil, width: width, height: height, bitsPerComponent: bitsPerComponent,
                         bytesPerRow: bytesPerRow, space: space, bitmapInfo: bitmapInfo)
    }
}

extension CGImage {
    /// `CGImage(width:height:bitsPerComponent:bitsPerPixel:bytesPerRow:space:bitmapInfo:provider:decode: nil,
    /// shouldInterpolate:intent:)`: an image of the provider's pixels with the default decode.
    static func make(width: Int, height: Int, bitsPerComponent: Int, bitsPerPixel: Int, bytesPerRow: Int,
                     space: CGColorSpace, bitmapInfo: CGBitmapInfo, provider: CGDataProvider, shouldInterpolate: Bool,
                     intent: CGColorRenderingIntent) -> CGImage? {
        // SAFETY: the decode-array pointer is nil (the default decode), so Core Graphics reads no memory through it.
        unsafe CGImage(width: width, height: height, bitsPerComponent: bitsPerComponent, bitsPerPixel: bitsPerPixel,
                       bytesPerRow: bytesPerRow, space: space, bitmapInfo: bitmapInfo, provider: provider, decode: nil,
                       shouldInterpolate: shouldInterpolate, intent: intent)
    }
}

extension CGContext {
    /// A copy of a bitmap context's pixel bytes (`bytesPerRow` x `height`, in memory order), read through an image
    /// of the context instead of its `data` pointer; nil when the context makes no image.
    func bitmapBytes() -> [UInt8]? {
        guard let data = makeImage()?.dataProvider?.data else { return nil }
        return [UInt8](data as Data)
    }
}

extension CGGradient {
    /// `CGGradient(colorsSpace:colors:locations:)` with one location per color; nil when the counts differ
    /// (Core Graphics would read a location past the array) or Core Graphics makes no gradient.
    static func checked(colorsSpace: CGColorSpace?, colors: [CGColor], locations: [CGFloat]) -> CGGradient? {
        guard colors.count == locations.count else { return nil }
        // SAFETY: Core Graphics reads colors.count locations, which is the array's count (checked above), during
        // the call only.
        return unsafe CGGradient(colorsSpace: colorsSpace, colors: colors as CFArray, locations: locations)
    }
}

extension NSBitmapImageRep {
    /// A bitmap image rep that allocates and owns its pixels (`bitmapDataPlanes: nil`); nil when AppKit cannot
    /// make it.
    static func owned(pixelsWide: Int, pixelsHigh: Int, bitsPerSample: Int, samplesPerPixel: Int, hasAlpha: Bool,
                      isPlanar: Bool, colorSpaceName: NSColorSpaceName, bitmapFormat: NSBitmapImageRep.Format = [],
                      bytesPerRow: Int, bitsPerPixel: Int) -> NSBitmapImageRep? {
        // SAFETY: the planes pointer is nil, so AppKit allocates the pixel memory and owns it for the rep's life;
        // no memory of the caller is read or written.
        unsafe NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixelsWide, pixelsHigh: pixelsHigh,
                                bitsPerSample: bitsPerSample, samplesPerPixel: samplesPerPixel, hasAlpha: hasAlpha,
                                isPlanar: isPlanar, colorSpaceName: colorSpaceName, bitmapFormat: bitmapFormat,
                                bytesPerRow: bytesPerRow, bitsPerPixel: bitsPerPixel)
    }
}

extension NSAttributedString {
    /// The value of attribute `name` at `location` (`attribute(_:at:effectiveRange: nil)`).
    func attribute(_ name: NSAttributedString.Key, at location: Int) -> Any? {
        // SAFETY: the effective-range pointer is nil, so Foundation writes no range.
        unsafe attribute(name, at: location, effectiveRange: nil)
    }

    /// The attributes at `location` (`attributes(at:effectiveRange: nil)`).
    func attributes(at location: Int) -> [NSAttributedString.Key: Any] {
        // SAFETY: the effective-range pointer is nil, so Foundation writes no range.
        unsafe attributes(at: location, effectiveRange: nil)
    }
}
