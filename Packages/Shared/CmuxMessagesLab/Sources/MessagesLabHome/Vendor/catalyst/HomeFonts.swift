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

    /// Inline code and code blocks in an agent's Markdown (TextLayout.attributed):
    /// SF Mono one point under the body. Built from the body font's monospaced
    /// design (the same font as `monospacedSystemFont(ofSize: 12, weight: .regular)`)
    /// through APIs that really return optionals, so a failure falls back to the
    /// user's fixed-pitch font instead of a nil inside the attributes.
    static let code: UIFont = {
        let size = Fixture.bodyFont.pointSize - 1
        #if canImport(UIKit)
        // crash-allow: made once in this static let and held for the process (the cx-qpqs cache itself)
        if let d = Fixture.bodyFont.fontDescriptor.withDesign(.monospaced) { return UIFont(descriptor: d, size: size) }
        // crash-allow: made once in this static let and held for the process (the cx-qpqs cache itself)
        return UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
        #else
        // crash-allow: made once in this static let and held for the process (the cx-qpqs cache itself)
        if let d = Fixture.bodyFont.fontDescriptor.withDesign(.monospaced), let f = UIFont(descriptor: d, size: size) { return f }
        // crash-allow: made once in this static let and held for the process (the cx-qpqs cache itself)
        return NSFont.userFixedPitchFont(ofSize: size) ?? Fixture.bodyFont
        #endif
    }()

    /// `systemFont(ofSize:weight:)` for the off-main row renderers (RowDrawing,
    /// MarkdownLayout): made once per size and weight and held for the life of
    /// the process, so no lookup races the release of the last instance. The
    /// nonnull annotation is not trusted: a nil from AppKit falls back to the
    /// body font with the weight through `UIFont(descriptor:size:)`, which
    /// returns an optional, and then to the body font itself.
    static func system(ofSize size: CGFloat, weight: Weight = .regular) -> UIFont {
        let key = Key(size: quantized(size), weight: weight.rawValue, traits: 0, monospaced: false)
        return cached(key) { makeSystem(key.size, weight) }
    }

    /// Not cached: `cached` calls it under the store's lock (not reentrant).
    private static func makeSystem(_ size: CGFloat, _ weight: Weight) -> UIFont {
        // crash-allow: made once under the HomeFonts store lock and held for the process (the cx-qpqs cache itself)
        if let font = unannotated(UIFont.systemFont(ofSize: size, weight: weight)) { return font }
        #if canImport(UIKit)
        let d = Fixture.bodyFont.fontDescriptor.addingAttributes([.traits: [UIFontDescriptor.TraitKey.weight: weight.rawValue]])
        // crash-allow: made once under the HomeFonts store lock and held for the process (the cx-qpqs cache itself)
        return UIFont(descriptor: d, size: size)
        #else
        let d = Fixture.bodyFont.fontDescriptor.addingAttributes([.traits: [UIFontDescriptor.TraitKey.weight: weight.rawValue]])
        // crash-allow: made once under the HomeFonts store lock and held for the process (the cx-qpqs cache itself)
        return NSFont(descriptor: d, size: size) ?? Fixture.bodyFont
        #endif
    }

    /// `monospacedSystemFont(ofSize:weight:)`, held like `system(ofSize:weight:)`.
    static func monospaced(ofSize size: CGFloat, weight: Weight = .regular) -> UIFont {
        let key = Key(size: quantized(size), weight: weight.rawValue, traits: 0, monospaced: true)
        return cached(key) {
            // crash-allow: made once under the HomeFonts store lock and held for the process (the cx-qpqs cache itself)
            if let font = unannotated(UIFont.monospacedSystemFont(ofSize: key.size, weight: weight)) { return font }
            #if canImport(UIKit)
            // crash-allow: made once under the HomeFonts store lock and held for the process (the cx-qpqs cache itself)
            if let d = Fixture.bodyFont.fontDescriptor.withDesign(.monospaced) { return UIFont(descriptor: d, size: key.size) }
            return Fixture.bodyFont
            #else
            // crash-allow: made once under the HomeFonts store lock and held for the process (the cx-qpqs cache itself)
            if let d = Fixture.bodyFont.fontDescriptor.withDesign(.monospaced), let f = UIFont(descriptor: d, size: key.size) { return f }
            // crash-allow: made once under the HomeFonts store lock and held for the process (the cx-qpqs cache itself)
            return NSFont.userFixedPitchFont(ofSize: key.size) ?? Fixture.bodyFont
            #endif
        }
    }

    /// `monospacedDigitSystemFont(ofSize:weight:)`, held like `system(ofSize:weight:)`.
    static func monospacedDigit(ofSize size: CGFloat, weight: Weight = .regular) -> UIFont {
        let key = Key(size: quantized(size), weight: weight.rawValue, traits: 0, monospaced: false, name: "digits")
        return cached(key) {
            // crash-allow: made once under the HomeFonts store lock and held for the process (the cx-qpqs cache itself)
            unannotated(UIFont.monospacedDigitSystemFont(ofSize: key.size, weight: weight)) ?? makeSystem(key.size, weight)
        }
    }

    /// `base` with `traits` added (bold, italic for a Markdown run), held per
    /// base font, size and traits; nil when the font has no such face, so a
    /// caller adds no font attribute instead of a nil (`addAttribute` would
    /// store NSNull for an optional and throw for a nil).
    static func font(_ base: UIFont, adding traits: UIFontDescriptor.SymbolicTraits) -> UIFont? {
        let all = base.fontDescriptor.symbolicTraits.union(traits)
        let key = Key(size: quantized(base.pointSize), weight: 0, traits: all.rawValue, monospaced: false, name: base.fontName)
        if let hit = store.withLock({ $0[key] }) { return hit }
        #if canImport(UIKit)
        guard let d = base.fontDescriptor.withSymbolicTraits(all) else { return nil }
        // crash-allow: made once under the HomeFonts store lock and held for the process (the cx-qpqs cache itself)
        let font = UIFont(descriptor: d, size: key.size)
        #else
        // crash-allow: made once under the HomeFonts store lock and held for the process (the cx-qpqs cache itself)
        guard let d = base.fontDescriptor.withSymbolicTraits(all), let font = UIFont(descriptor: d, size: key.size) else { return nil }
        #endif
        return store.withLock { fonts in
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

    private static let store = OSAllocatedUnfairLock<[Key: UIFont]>(initialState: [:])

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

    private static func cached(_ key: Key, make: () -> UIFont) -> UIFont {
        // Made under the lock: one creation per key, and no thread drops it.
        // `make` must not call back into the store (the lock is not reentrant).
        store.withLock { fonts in
            if let held = fonts[key] { return held }
            let font = make()
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

