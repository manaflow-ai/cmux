import AppKit
import CoreText
import os

/// The one way chrome code gets a UI font (`Typography.system`): the default design is the bundled
/// UI font, Inter (`BundledFonts`), the monospaced designs the system's. ``system(_:size:weight:)``
/// makes each (design, size, weight) font once and keeps it for the process.
///
/// Why: AppKit's monospaced system font constructors
/// (`monospacedSystemFont`, `monospacedDigitSystemFont`) are imported as
/// non-optional, yet they return nil now and then when code makes a fresh
/// font on every call and drops it at once (a computed `var font: NSFont {
/// .monospacedSystemFont(...) }` read in `draw`). The keycap view did that
/// on every measure and draw; nxtip3-v1 and nxdog99-v1 (macOS 27, 2026-10-14)
/// got a nil `Typography.shortcut` on the main thread 3 to 23 s after launch.
/// Swift carries the null reference, and the first string measured or drawn
/// with `[.font: nil]` aborts: CoreText finds no font, copies the attributes
/// to apply its default one, and the copy throws "attempt to insert nil
/// object" (issue #20557). A probe (make the font, measure "⌘K" with it,
/// drop it, on the main thread) got nil in 4661 and 19382 of 300 000 calls
/// on macOS 27.0.1 (-Onone, -O) and 71 and 41 on macOS 26.5; one retained
/// font per size got nil in none of 600 000 calls on either.
///
/// ``resolve(size:_:)`` stays as the defense: it checks every new font and
/// falls back, so a font handed to string drawing is never null.
enum CheckedFont {
    private struct Key: Hashable {
        var design: Typography.Design
        var size: CGFloat
        var weight: CGFloat
    }

    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "fonts")
    /// The last font AppKit returned non-null; the end of the fallback chain.
    private static var lastGood: NSFont?
    /// Every font ``system(_:size:weight:)`` made, kept alive for the
    /// process. Sizes come from clamped settings (interface scale 0.85 to
    /// 1.5, interface size 10 to 16, density); each setting a user steps
    /// through adds about 15 keys, so the cap leaves room for well over 100
    /// of them in one session. Past the cap a new font is still checked but
    /// not kept. No eviction: releasing a font is what lets the next request
    /// for it come back nil.
    private static var retained: [Key: NSFont] = [:]
    private static let retainedLimit = 2048

    /// The system font of `design` at `size` (rounded to 1/100 pt) and
    /// `weight`: the retained one when this process made it before, else a
    /// new checked one that is kept. Main actor only (the module default).
    static func system(_ design: Typography.Design, size requested: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        // A non-finite size never equals itself as a key: check it, never keep it.
        guard requested.isFinite else {
            return checked(size: requested) { fresh(design, size: NSFont.systemFontSize, weight: weight) }.font
        }
        let size = (requested * 100).rounded() / 100
        let key = Key(design: design, size: size, weight: weight.rawValue)
        if let font = retained[key] { return font }
        let (font, isFallback) = checked(size: size) { fresh(design, size: size, weight: weight) }
        // A fallback is not kept: the next call asks AppKit again.
        if !isFallback, retained.count < retainedLimit { retained[key] = font }
        return font
    }

    private static func fresh(_ design: Typography.Design, size: CGFloat, weight: NSFont.Weight) -> NSFont {
        switch design {
        // The UI font, Inter (`BundledFonts`, Leo 2026-10-21); the system font when it is missing.
        case .default: BundledFonts.uiFont(size: size, weight: weight) ?? .systemFont(ofSize: size, weight: weight)
        case .monospaced: .monospacedSystemFont(ofSize: size, weight: weight)
        case .monospacedDigit: .monospacedDigitSystemFont(ofSize: size, weight: weight)
        }
    }

    /// `font` as an optional, so a null reference from a non-optional
    /// import can be tested. Not inlined, so the optimizer cannot assume the
    /// non-optional type and fold the test away.
    @inline(never)
    nonisolated static func nonNull(_ font: NSFont) -> NSFont? {
        unsafeBitCast(font, to: NSFont?.self)
    }

    /// The font `make` returns, else the system font at `size`, else
    /// Helvetica from CoreText, else the last font that resolved here. Logs
    /// each fallback (a fault: AppKit broke its non-null contract). Prefer
    /// ``system(_:size:weight:)``, which also keeps the font alive.
    static func resolve(size: CGFloat, _ make: () -> NSFont) -> NSFont {
        checked(size: size, make).font
    }

    private static func checked(size: CGFloat, _ make: () -> NSFont) -> (font: NSFont, isFallback: Bool) {
        if let font = nonNull(make()) {
            lastGood = font
            return (font, false)
        }
        let pointSize = size.isFinite && size > 0 ? size : NSFont.systemFontSize
        logger.fault("AppKit returned a nil font at \(Double(size), privacy: .public) pt; falling back")
        let system = NSFont.systemFont(ofSize: pointSize)
        if let font = nonNull(system) { return (font, true) }
        let helvetica = unsafeBitCast(CTFontCreateWithName("Helvetica" as CFString, pointSize, nil), to: NSFont.self)
        if let font = nonNull(helvetica) { return (font, true) }
        // The last resolved font is at another size, but never null once any
        // font resolved in this process (the first chrome draw does).
        return (lastGood ?? helvetica, true)
    }
}
