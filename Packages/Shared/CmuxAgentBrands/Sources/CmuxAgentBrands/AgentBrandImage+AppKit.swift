#if canImport(AppKit)
import AppKit

public extension AgentBrandCatalog {
    /// A template image of a brand's mark (the mono style) for AppKit views that tint
    /// templates (`NSImageView.contentTintColor`, menus). It draws at the screen's scale
    /// whenever AppKit renders it. Nil when the brand has no mark.
    static func templateImage(brand: String, size: CGFloat, fill: CGFloat = 0.86) -> NSImage? {
        guard let spec = spec(for: AgentBrandID(rawValue: brand)), size > 0 else { return nil }
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let side = rect.width * fill
            let box = CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)
            AgentBrandRenderer.draw(spec, in: context, rect: box, style: .mono, dark: false,
                                    monoColor: CGColor(gray: 0, alpha: 1), flipped: false)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = spec.name
        return image
    }
}
#endif
