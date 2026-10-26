import AppKit
import CmuxNextDesign
import CoreText

/// The icon a user set on a tab (ICON-PICKER-ALL-EMOJI-AND-SF-SYMBOLS), as the
/// strip draws it: an emoji becomes a full-color image (drawn as is, like a
/// favicon), an SF Symbol stays a tinted symbol, a stored image or SVG asset is
/// the image `asset` draws (the App reads it from the tab's daemon). Nil for no
/// icon, an invalid wire string, a symbol this Mac cannot draw (a newer
/// system's name), or an asset not read yet, so the tab keeps its kind icon.
public struct TabUserIcon {
    public static let shared = TabUserIcon()

    public init() {}

    /// Pixels of the side of a drawn emoji: the icon box at 3x, so it stays sharp at every scale.
    static let emojiPixels = 48

    public func icon(_ wire: String?, asset: (String) -> TabImage? = { _ in nil }) -> TabIcon? {
        switch IconValue(wire: wire) {
        case .emoji(let text)?: TabUserIconImages.shared.emoji(text).map { .image($0) }
        case .symbol(let name)?: TabUserIconImages.shared.draws(symbol: name) ? .symbol(name) : nil
        case .image?, .svg?: wire.flatMap(asset).map { .image($0) }
        case nil: nil
        }
    }
}

/// Drawn emoji and known symbol names, cached (a tab strip snapshot runs on
/// every model change, so neither is recomputed per snapshot). Each is a memory
/// consumer (``TabImageMemo``: `tab-user-emoji`, `tab-user-symbol-names`) the app
/// registers through ``TabIconMemoryConsumers``.
final class TabUserIconImages {
    static let shared = TabUserIconImages()
    let emojiImages: TabImageMemo<TabImage>
    let symbolNames: TabImageMemo<Bool>
    private static let limit = 256

    /// - Parameter clock: Times how long a drawn emoji or a looked-up name stays in use; tests pass their own.
    init(clock: any Clock<Duration> = ContinuousClock()) {
        emojiImages = TabImageMemo(name: "tab-user-emoji", capacity: Self.limit,
                                   bytes: { TabImageMemo<CGImage>.pixelBytes($0.cgImage) }, clock: clock)
        symbolNames = TabImageMemo(name: "tab-user-symbol-names", capacity: Self.limit, bytes: { _ in 0 }, clock: clock)
    }

    func draws(symbol name: String) -> Bool {
        symbolNames.value(for: name) { NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil } ?? false
    }

    func emoji(_ text: String) -> TabImage? {
        emojiImages.value(for: text) { Self.draw(text, pixels: TabUserIcon.emojiPixels).map(TabImage.init) }
    }

    /// `text` in the system emoji font, centered on a clear square of `pixels`.
    static func draw(_ text: String, pixels: Int) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let side = CGFloat(pixels)
        // Apple Color Emoji's glyph box is about 1.2 em tall; 0.8 em fills the square.
        let font = CTFontCreateWithName("AppleColorEmoji" as CFString, side * 0.8, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
        let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        context.textPosition = CGPoint(x: (side - bounds.width) / 2 - bounds.minX, y: (side - bounds.height) / 2 - bounds.minY)
        CTLineDraw(line, context)
        return context.makeImage()
    }
}
