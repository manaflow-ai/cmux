import AppKit
import os

/// Fonts the off-main row renderers share for the life of the process.
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
    /// Inline code and code blocks in an agent's Markdown (TextLayout.attributed):
    /// SF Mono one point under the body. Built from the body font's monospaced
    /// design (the same font as `monospacedSystemFont(ofSize: 12, weight: .regular)`)
    /// through APIs that really return optionals, so a failure falls back to the
    /// user's fixed-pitch font instead of a nil inside the attributes.
    static let code: NSFont = {
        let size = Fixture.bodyFont.pointSize - 1
        if let d = Fixture.bodyFont.fontDescriptor.withDesign(.monospaced), let f = NSFont(descriptor: d, size: size) { return f }
        return NSFont.userFixedPitchFont(ofSize: size) ?? Fixture.bodyFont
    }()

    /// `systemFont(ofSize:weight:)` for the off-main row renderers (RowDrawing,
    /// MarkdownLayout): made once per size and weight and held for the life of
    /// the process, so no lookup races the release of the last instance. The
    /// nonnull annotation is not trusted: a nil from AppKit falls back to the
    /// body font with the weight through `NSFont(descriptor:size:)`, which
    /// returns an optional, and then to the body font itself.
    static func system(ofSize size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        let key = Key(size: quantized(size), weight: weight.rawValue, traits: 0, monospaced: false)
        return cached(key) { makeSystem(key.size, weight) }
    }

    /// Not cached: `cached` calls it under the store's lock (not reentrant).
    private static func makeSystem(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
        if let font = unannotated(NSFont.systemFont(ofSize: size, weight: weight)) { return font }
        let d = Fixture.bodyFont.fontDescriptor.addingAttributes([.traits: [NSFontDescriptor.TraitKey.weight: weight.rawValue]])
        return NSFont(descriptor: d, size: size) ?? Fixture.bodyFont
    }

    /// `monospacedSystemFont(ofSize:weight:)`, held like `system(ofSize:weight:)`.
    static func monospaced(ofSize size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        let key = Key(size: quantized(size), weight: weight.rawValue, traits: 0, monospaced: true)
        return cached(key) {
            if let font = unannotated(NSFont.monospacedSystemFont(ofSize: key.size, weight: weight)) { return font }
            if let d = Fixture.bodyFont.fontDescriptor.withDesign(.monospaced), let f = NSFont(descriptor: d, size: key.size) { return f }
            return NSFont.userFixedPitchFont(ofSize: key.size) ?? Fixture.bodyFont
        }
    }

    /// `monospacedDigitSystemFont(ofSize:weight:)`, held like `system(ofSize:weight:)`.
    static func monospacedDigit(ofSize size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        let key = Key(size: quantized(size), weight: weight.rawValue, traits: 0, monospaced: false, name: "digits")
        return cached(key) {
            unannotated(NSFont.monospacedDigitSystemFont(ofSize: key.size, weight: weight)) ?? makeSystem(key.size, weight)
        }
    }

    /// `base` with `traits` added (bold, italic for a Markdown run), held per
    /// base font, size and traits; nil when the font has no such face, so a
    /// caller adds no font attribute instead of a nil (`addAttribute` would
    /// store NSNull for an optional and throw for a nil).
    static func font(_ base: NSFont, adding traits: NSFontDescriptor.SymbolicTraits) -> NSFont? {
        let all = base.fontDescriptor.symbolicTraits.union(traits)
        let key = Key(size: quantized(base.pointSize), weight: 0, traits: all.rawValue, monospaced: false, name: base.fontName)
        if let hit = store.withLock({ $0[key] }) { return hit }
        guard let d = base.fontDescriptor.withSymbolicTraits(all), let font = NSFont(descriptor: d, size: key.size) else { return nil }
        return store.withLock { fonts in
            if let held = fonts[key] { return held }
            fonts[key] = font
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

    private static let store = OSAllocatedUnfairLock<[Key: NSFont]>(initialState: [:])

    /// Sizes to the half point, so a size computed from a frame (a reaction
    /// glyph at 42% of its circle) does not grow the store without bound.
    private static func quantized(_ size: CGFloat) -> CGFloat { (size * 2).rounded() / 2 }

    private static func cached(_ key: Key, make: () -> NSFont) -> NSFont {
        // Made under the lock: one creation per key, and no thread drops it.
        // `make` must not call back into the store (the lock is not reentrant).
        store.withLock { fonts in
            if let held = fonts[key] { return held }
            let font = make()
            fonts[key] = font
            return font
        }
    }

    /// The reference an AppKit factory annotated nonnull returned, read as an
    /// optional: under concurrency these factories can return nil (cx-qpqs),
    /// and Swift would trust the annotation.
    private static func unannotated(_ font: NSFont) -> NSFont? {
        unsafeBitCast(font, to: NSFont?.self)
    }
}

