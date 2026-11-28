import AppKit
import CmuxNextIcons

/// Icons from the cmux icon pack drawn in the tab's tint, filling the icon
/// box, cached per name, tint, size, and scale.
final class TabPackIconCache {
    static let shared = TabPackIconCache()
    private var cache: [String: CGImage] = [:]

    func image(name: IconName, tint: NSColor, size: CGFloat, scale: CGFloat) -> CGImage? {
        let resolved = tint.usingColorSpace(.sRGB) ?? tint
        let key = "\(name.rawValue)|\(resolved.redComponent)|\(resolved.greenComponent)|\(resolved.blueComponent)|\(resolved.alphaComponent)|\(size)|\(scale)"
        if let cached = cache[key] { return cached }
        guard let image = CGImage.icon(name, size: size, scale: scale, tint: resolved.cgColor) else { return nil }
        if cache.count > 256 { cache.removeAll() }
        cache[key] = image
        return image
    }
}
