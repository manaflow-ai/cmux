import AppKit
import CoreText
import os

/// AppKit's system font constructors (`NSFont.systemFont`,
/// `monospacedSystemFont`, `monospacedDigitSystemFont`) are imported as
/// non-optional, yet they can return nil: nxtip3-v1 (macOS 27, 2026-10-14
/// 01:42) got nil from `monospacedSystemFont(ofSize: 11, weight: .medium)` on
/// the main thread. Swift then carries a null `NSFont`, and the first string
/// measured or drawn with it in `[.font: font]` aborts: CoreText finds no font,
/// copies the attributes to apply its default one, and the copy throws
/// "attempt to insert nil object". A nil color in the same dictionary does
/// not abort. The size was ruled out: NaN, 0, negative and infinite sizes
/// all return a font on macOS 27.0.1.
///
/// Every `Typography` font goes through ``CheckedFont/resolve(size:_:)``,
/// which checks the result and falls back, so a font handed to string
/// drawing is never null.
enum CheckedFont {
    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "fonts")
    /// The last font AppKit returned non-null; the end of the fallback chain.
    private static var lastGood: NSFont?

    /// `font` as an optional, so a null reference from a non-optional
    /// import can be tested. Not inlined, so the optimizer cannot assume the
    /// non-optional type and fold the test away.
    @inline(never)
    nonisolated static func nonNull(_ font: NSFont) -> NSFont? {
        unsafeBitCast(font, to: NSFont?.self)
    }

    /// The font `make` returns, else the system font at `size`, else
    /// Helvetica from CoreText, else the last font that resolved here. Logs
    /// each fallback (a fault: AppKit broke its non-null contract).
    static func resolve(size: CGFloat, _ make: () -> NSFont) -> NSFont {
        if let font = nonNull(make()) {
            lastGood = font
            return font
        }
        let pointSize = size.isFinite && size > 0 ? size : NSFont.systemFontSize
        logger.fault("AppKit returned a nil font at \(Double(size), privacy: .public) pt; falling back")
        let system = NSFont.systemFont(ofSize: pointSize)
        if let font = nonNull(system) { return font }
        let helvetica = unsafeBitCast(CTFontCreateWithName("Helvetica" as CFString, pointSize, nil), to: NSFont.self)
        if let font = nonNull(helvetica) { return font }
        // The last resolved font is at another size, but never null once any
        // font resolved in this process (the first chrome draw does).
        return lastGood ?? helvetica
    }
}
