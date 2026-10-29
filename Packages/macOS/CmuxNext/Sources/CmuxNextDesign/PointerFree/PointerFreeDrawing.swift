import AppKit
public import CoreGraphics

// The Core Graphics and TextKit initializers and methods Design and Sidebar call with a pointer they
// never use (a nil transform, pixel buffer or out-parameter), each written once so the callers stay pointer-free
// (strict memory safety). Chromium keeps each UNSAFE_BUFFERS() in one checked
// helper in the same way instead of at every use (docs/unsafe_buffers.md).
// The paths need no `unsafe` at all: CGMutablePath's add calls take their transform by value.

public nonisolated extension CGPath {
    /// `rect` with elliptical corners `cornerWidth` x `cornerHeight`: the path
    /// `CGPath(roundedRect:cornerWidth:cornerHeight:transform: nil)` makes, built without the
    /// transform pointer. Each corner must fit half the rect's side, as Core Graphics requires.
    static func roundedRect(_ rect: CGRect, cornerWidth: CGFloat, cornerHeight: CGFloat) -> CGPath {
        let path = CGMutablePath()
        path.addRoundedRect(in: rect, cornerWidth: cornerWidth, cornerHeight: cornerHeight)
        return path
    }

    /// `rect` as a closed path (`CGPath(rect:transform: nil)`).
    static func rect(_ rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        path.addRect(rect)
        return path
    }

    /// The ellipse inscribed in `rect` (`CGPath(ellipseIn:transform: nil)`).
    static func ellipse(in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        path.addEllipse(in: rect)
        return path
    }
}

public nonisolated extension CGContext {
    /// An 8-bit-per-component bitmap context whose pixels Core Graphics allocates, owns and frees with the
    /// context; callers read it back through `makeImage()`, so no Swift pointer to the pixels exists.
    ///
    /// - Parameters:
    ///   - width: Pixels across.
    ///   - height: Pixels down.
    ///   - bytesPerRow: The row size; 0 lets Core Graphics pick it.
    ///   - space: The color space.
    ///   - bitmapInfo: The alpha and byte-order layout (`CGImageAlphaInfo` and `CGBitmapInfo` bits).
    /// - Returns: The context, or nil when Core Graphics refuses the size or format.
    static func pixelOwningBitmap(width: Int, height: Int, bytesPerRow: Int = 0, space: CGColorSpace,
                                  bitmapInfo: UInt32) -> CGContext? {
        // SAFETY: `data` is nil, so Core Graphics allocates a buffer sized from the width, height and row bytes and
        // frees it with the context; nothing is read or written through a pointer passed from here.
        unsafe CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                         space: space, bitmapInfo: bitmapInfo)
    }
}

nonisolated extension NSLayoutManager {
    /// The characters of `glyphRange` (`characterRange(forGlyphRange:actualGlyphRange: nil)`).
    func characterRange(ofGlyphs glyphRange: NSRange) -> NSRange {
        // SAFETY: the actual-range pointer is nil, which TextKit documents as "not wanted"; nothing is written.
        unsafe characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
    }

    /// The glyphs of `characterRange` (`glyphRange(forCharacterRange:actualCharacterRange: nil)`).
    func glyphRange(ofCharacters characterRange: NSRange) -> NSRange {
        // SAFETY: the actual-range pointer is nil, which TextKit documents as "not wanted"; nothing is written.
        unsafe glyphRange(forCharacterRange: characterRange, actualCharacterRange: nil)
    }

    /// The line fragment rect of the glyph at `glyphIndex` (`lineFragmentRect(forGlyphAt:effectiveRange: nil)`).
    func lineFragmentRect(ofGlyphAt glyphIndex: Int) -> NSRect {
        // SAFETY: the effective-range pointer is nil, which TextKit documents as "not wanted"; nothing is written.
        unsafe lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
    }
}

nonisolated extension NSAttributedString {
    /// The attributes of the character at `index` (`attributes(at:effectiveRange: nil)`).
    func attributes(atCharacter index: Int) -> [NSAttributedString.Key: Any] {
        // SAFETY: the effective-range pointer is nil, which Foundation documents as "not wanted"; nothing is written.
        unsafe attributes(at: index, effectiveRange: nil)
    }
}
