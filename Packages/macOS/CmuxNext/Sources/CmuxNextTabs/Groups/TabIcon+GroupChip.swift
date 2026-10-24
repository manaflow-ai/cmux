import AppKit
import CmuxNextDesign
import CmuxNextIcons

extension TabIcon {
    /// The image a group chip draws for this icon, at `size` points: a symbol,
    /// pack icon or agent mark tinted `tint` (the chip's text color), an image
    /// (an emoji drawn to an image, a stored asset) as is, from `caches`, the
    /// ones the strip's tab cells draw from (`TabCell.iconImage`). Nil for `.none`.
    func groupChipImage(tint: NSColor, size: CGFloat, scale: CGFloat, caches: TabIconCaches) -> CGImage? {
        switch self {
        case .none: nil
        case .image(let image): image.cgImage
        case .symbol(let name):
            caches.symbols.image(named: name, tint: tint, pointSize: Metrics.smallIconSize, size: size, scale: scale)
        case .icon(let name): caches.packIcons.image(name: name, tint: tint, size: size, scale: scale)
        case .agentMark(let brand): caches.agentMarks.image(brand: brand, tint: tint, size: size, scale: scale)
        }
    }
}
