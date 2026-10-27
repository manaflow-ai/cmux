import AppKit
import CmuxNextCompatAppKit
import CmuxNextDesign
import CmuxNextTabs

/// Draws an emoji screen icon into a `TabImage` at the tab icon size. The
/// cache keeps one image per emoji and backing scale.
@MainActor
enum ScreenEmojiIcon {
    // memory: fixed at most 65 images (emptied past 64): each one tab icon (16 pt) at its backing scale, under 10 KB at 3x
    private static var cache: [String: TabImage] = [:]

    static func icon(_ emoji: String) -> TabIcon {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let key = "\(emoji)@\(scale)"
        if let image = cache[key] { return .image(image) }
        guard let image = render(emoji, scale: scale) else { return .none }
        if cache.count > 64 { cache.removeAll() }
        cache[key] = image
        return .image(image)
    }

    private static func render(_ emoji: String, scale: CGFloat) -> TabImage? {
        let side = TabStripMetrics.standard.iconSize
        let pixels = Int((side * scale).rounded())
        guard pixels > 0, let context = CGContext.bitmapOwningPixels(width: pixels, height: pixels,
                                                                     space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        let font = NSFont.systemFont(ofSize: side * 0.82)
        let text = NSAttributedString(string: emoji, attributes: [.font: font])
        let size = text.size()
        text.draw(at: CGPoint(x: (side - size.width) / 2, y: (side - size.height) / 2))
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage().map(TabImage.init)
    }
}
