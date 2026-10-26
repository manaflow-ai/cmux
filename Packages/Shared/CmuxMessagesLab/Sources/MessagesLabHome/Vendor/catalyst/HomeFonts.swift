#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif
import os

// Shared by appkit-native (AppKit, `UIFont` is NSFont through the appkit-port shim), Catalyst
// and iOS (UIKit), and by cmux-next, which vendors these sources (cx-3cb).

/// Fonts the off-main row renderers share for the life of the process.
/// (`Home` is cmux-next's name for the transcript tab that vendors this code.)
///
/// AppKit's `monospacedSystemFont(ofSize:weight:)` is annotated nonnull but
/// returns nil when another thread releases the last instance of that font
/// while the lookup runs (measured on macOS 27.0.1: about 1 in 1000 calls
/// from 8 threads that each make and drop the font; 0 while one instance
/// stays alive). RowBitmaps renders three rows at once and a resize
/// re-renders every visible row, so a code font made and dropped per run
/// came back nil and `addAttribute` threw "nil value" (cx-qpqs). One font
/// held here keeps the instance alive, so no lookup races its release.
enum HomeFonts {
    #if canImport(UIKit)
    typealias Weight = UIFont.Weight
    #else
    typealias Weight = NSFont.Weight
    #endif

    /// cmux: the body face (`Fixture.bodyFont`), the system font at 13 pt, held in the store like
    /// every font here (a `static let` of NSFont is a global of a non-Sendable type). It is the
    /// base of every fallback below.
    static var body: UIFont {
        store.withLockUnchecked { fonts in
            if let held = fonts[bodyKey] { return held }
            let font = makeSystem(bodyKey.size, .regular, base: nil)
            fonts.updateValue(font, forKey: bodyKey) // dictionary write
            return font
        }
    }
    private static let bodyKey = Key(size: 13, weight: 0, traits: 0, monospaced: false, name: "body")

    /// Inline code and code blocks in an agent's Markdown (TextLayout.attributed):
    /// SF Mono one point under the body. Built from the body font's monospaced
    /// design (the same font as `monospacedSystemFont(ofSize: 12, weight: .regular)`)
    /// through APIs that really return optionals, so a failure falls back to the
    /// user's fixed-pitch font instead of a nil inside the attributes.
    /// cmux: made once in the store and always held, as the body font (it was a `static let` of NSFont).
    static var code: UIFont {
        let base = body
        return store.withLockUnchecked { fonts in
            if let held = fonts[codeKey] { return held }
            let font = makeCode(base)
            fonts.updateValue(font, forKey: codeKey) // dictionary write
            return font
        }
    }
    private static let codeKey = Key(size: 12, weight: 0, traits: 0, monospaced: true, name: "code")

    /// Not cached: `cached` calls it under the store's lock.
    private static func makeCode(_ base: UIFont) -> UIFont {
        let size = base.pointSize - 1
        #if canImport(UIKit)
        // crash-allow: made once under the HomeFonts store lock and held for the process (the cx-qpqs cache itself)
        if let d = base.fontDescriptor.withDesign(.monospaced) { return UIFont(descriptor: d, size: size) }
        // crash-allow: made once under the HomeFonts store lock and held for the process (the cx-qpqs cache itself)
        return UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
        #else
        // crash-allow: made once under the HomeFonts store lock and held for the process (the cx-qpqs cache itself)
        if let d = base.fontDescriptor.withDesign(.monospaced), let f = UIFont(descriptor: d, size: size) { return f }
        // crash-allow: made once under the HomeFonts store lock and held for the process (the cx-qpqs cache itself)
        return NSFont.userFixedPitchFont(ofSize: size) ?? base
        #endif
    }

    /// `systemFont(ofSize:weight:)` for the off-main row renderers (RowDrawing,
    /// MarkdownLayout): made once per size and weight and held for the life of
    /// the process, so no lookup races the release of the last instance. The
    /// nonnull annotation is not trusted: a nil from AppKit falls back to the
    /// body font with the weight through `UIFont(descriptor:size:)`, which
    /// returns an optional, and then to the body font itself.
    static func system(ofSize size: CGFloat, weight: Weight = .regular) -> UIFont {
        let key = Key(size: quantized(size), weight: weight.rawValue, traits: 0, monospaced: false)
        return cached(key) { base in makeSystem(key.size, weight, base: base) }
    }

    /// Not cached: `cached` calls it under the store's lock (not reentrant). `base`: the body font
    /// the fallbacks start from (cmux: nil while the body font itself is made).
    private static func makeSystem(_ size: CGFloat, _ weight: Weight, base: UIFont?) -> UIFont {
        // crash-allow: made once under the HomeFonts store lock and held for the process (the cx-qpqs cache itself)
        if let font = unannotated(UIFont.systemFont(ofSize: size, weight: weight)) { return font }
        #if canImport(UIKit)
        // cmux: the body font has no base of its own; the body text style is its last resort.
        guard let base else { return UIFont.preferredFont(forTextStyle: .body) }
        let d = base.fontDescriptor.addingAttributes([.traits: [UIFontDescriptor.TraitKey.weight: weight.rawValue]])
        // crash-allow: made once under the HomeFonts store lock and held for the process (the cx-qpqs cache itself)
        return UIFont(descriptor: d, size: size)
        #else
        // cmux: the body font has no base of its own; the label font is its last resort.
        guard let base else { return NSFont.labelFont(ofSize: size) }
        let d = base.fontDescriptor.addingAttributes([.traits: [UIFontDescriptor.TraitKey.weight: weight.rawValue]])
        // crash-allow: made once under the HomeFonts store lock and held for the process (the cx-qpqs cache itself)
        return NSFont(descriptor: d, size: size) ?? base
        #endif
    }

    /// `monospacedSystemFont(ofSize:weight:)`, held like `system(ofSize:weight:)`.
    static func monospaced(ofSize size: CGFloat, weight: Weight = .regular) -> UIFont {
        let key = Key(size: quantized(size), weight: weight.rawValue, traits: 0, monospaced: true)
        return cached(key) { base in
            // crash-allow: made once under the HomeFonts store lock and held for the process (the cx-qpqs cache itself)
            if let font = unannotated(UIFont.monospacedSystemFont(ofSize: key.size, weight: weight)) { return font }
            #if canImport(UIKit)
            // crash-allow: made once under the HomeFonts store lock and held for the process (the cx-qpqs cache itself)
            if let d = base.fontDescriptor.withDesign(.monospaced) { return UIFont(descriptor: d, size: key.size) }
            return base
            #else
            // crash-allow: made once under the HomeFonts store lock and held for the process (the cx-qpqs cache itself)
            if let d = base.fontDescriptor.withDesign(.monospaced), let f = UIFont(descriptor: d, size: key.size) { return f }
            // crash-allow: made once under the HomeFonts store lock and held for the process (the cx-qpqs cache itself)
            return NSFont.userFixedPitchFont(ofSize: key.size) ?? base
            #endif
        }
    }

    /// `monospacedDigitSystemFont(ofSize:weight:)`, held like `system(ofSize:weight:)`.
    static func monospacedDigit(ofSize size: CGFloat, weight: Weight = .regular) -> UIFont {
        let key = Key(size: quantized(size), weight: weight.rawValue, traits: 0, monospaced: false, name: "digits")
        return cached(key) { base in
            // crash-allow: made once under the HomeFonts store lock and held for the process (the cx-qpqs cache itself)
            unannotated(UIFont.monospacedDigitSystemFont(ofSize: key.size, weight: weight)) ?? makeSystem(key.size, weight, base: base)
        }
    }

    /// `base` with `traits` added (bold, italic for a Markdown run), held per
    /// base font, size and traits; nil when the font has no such face, so a
    /// caller adds no font attribute instead of a nil (`addAttribute` would
    /// store NSNull for an optional and throw for a nil).
    static func font(_ base: UIFont, adding traits: UIFontDescriptor.SymbolicTraits) -> UIFont? {
        let all = base.fontDescriptor.symbolicTraits.union(traits)
        let key = Key(size: quantized(base.pointSize), weight: 0, traits: all.rawValue, monospaced: false, name: base.fontName)
        if let hit = store.withLockUnchecked({ $0[key] }) { return hit }
        #if canImport(UIKit)
        guard let d = base.fontDescriptor.withSymbolicTraits(all) else { return nil }
        // crash-allow: made once under the HomeFonts store lock and held for the process (the cx-qpqs cache itself)
        let font = UIFont(descriptor: d, size: key.size)
        #else
        // crash-allow: made once under the HomeFonts store lock and held for the process (the cx-qpqs cache itself)
        guard let d = base.fontDescriptor.withSymbolicTraits(all), let font = UIFont(descriptor: d, size: key.size) else { return nil }
        #endif
        return store.withLockUnchecked { fonts in
            if let held = fonts[key] { return held }
            if fonts.count < limit { fonts.updateValue(font, forKey: key) } else { full() } // dictionary write
            return font
        }
    }

    private struct Key: Hashable {
        var size: CGFloat
        var weight: CGFloat
        var traits: UInt32
        var monospaced: Bool
        var name = ""
    }

    // cmux: NSFont is not Sendable, so the store is the lock's unchecked form (p10-stability-040).
    // Lock carve-out: the row renderers make and read fonts synchronously on their own threads.
    // Safe: a held font is never mutated, and Core Text documents its font objects (NSFont is
    // toll-free bridged to CTFont) as usable from several threads at once.
    private static let store = OSAllocatedUnfairLock<[Key: UIFont]>(uncheckedState: [:])

    /// The exact size: a rounded size draws other pixels (the HA HA glyph is 42% of its box,
    /// 7.56 pt, which a half-point store drew at 7.5 pt). The store is bounded by `limit`
    /// instead, so sizes computed from frames cannot grow it without bound.
    private static func quantized(_ size: CGFloat) -> CGFloat { size }
    /// At most this many held fonts; past it a font is made and returned unheld, so a lookup can
    /// race its release again (cx-qpqs; the fallbacks above keep a nil out of the attributes).
    /// The first time the store is full a process logs a fault (a full store means a caller
    /// passes sizes that change per frame).
    private static let limit = 512
    private static let fullLogged = OSAllocatedUnfairLock(initialState: false)
    private static func full() {
        guard fullLogged.withLock({ logged in defer { logged = true }; return !logged }) else { return }
        Logger(subsystem: "com.cmux.prototype.messageslab", category: "fonts")
            .fault("HomeFonts store is full (\(limit, privacy: .public) fonts): later fonts are not held")
    }

    private static func cached(_ key: Key, make: (UIFont) -> UIFont) -> UIFont {
        if let held = store.withLockUnchecked({ $0[key] }) { return held }
        // Made under the lock: one creation per key, and no thread drops it.
        // `make` must not call back into the store (the lock is not reentrant); cmux: it gets the
        // body font, taken before the lock, as the base of its fallbacks.
        let base = body
        return store.withLockUnchecked { fonts in
            if let held = fonts[key] { return held }
            let font = make(base)
            if fonts.count < limit { fonts.updateValue(font, forKey: key) } else { full() } // dictionary write
            return font
        }
    }

    /// The reference an AppKit factory annotated nonnull returned, read as an
    /// optional: under concurrency these factories can return nil (cx-qpqs),
    /// and Swift would trust the annotation.
    private static func unannotated(_ font: UIFont) -> UIFont? {
        unsafeBitCast(font, to: UIFont?.self)
    }
}
