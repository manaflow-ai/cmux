import AppKit
import CmuxNextIcons

/// Icons from the cmux icon pack drawn in the tab's tint, filling the icon
/// box, cached per name, tint, size, and scale: a memory consumer (`tab-pack-icons`,
/// ``TabImageMemo``) the app registers through ``TabIconMemoryConsumers``.
final class TabPackIconCache {
    static let shared = TabPackIconCache()
    let images: TabImageMemo<CGImage>

    /// - Parameter clock: Times how long a drawn icon stays in use; tests pass their own.
    init(clock: any Clock<Duration> = ContinuousClock()) {
        images = TabImageMemo(name: "tab-pack-icons", capacity: 256, bytes: TabImageMemo<CGImage>.pixelBytes(_:), clock: clock)
    }

    func image(name: IconName, tint: NSColor, size: CGFloat, scale: CGFloat) -> CGImage? {
        let resolved = tint.usingColorSpace(.sRGB) ?? tint
        let key = "\(name.rawValue)|\(resolved.redComponent)|\(resolved.greenComponent)|\(resolved.blueComponent)|\(resolved.alphaComponent)|\(size)|\(scale)"
        return images.value(for: key) { CGImage.icon(name, size: size, scale: scale, tint: resolved.cgColor) }
    }
}
