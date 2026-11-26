#if canImport(AppKit)
import AppKit

public extension AgentBrandCatalog {
    /// A template image of a brand's mark (the mono style) for AppKit views that tint
    /// templates (`NSImageView.contentTintColor`, menus). It draws at the screen's scale
    /// whenever AppKit renders it. Nil when the brand has no mark.
    /// `terminal` (an agent running in a terminal tab) draws the mark smaller on a soft rounded square
    /// (`terminalTileCornerShare`, `terminalTileAlpha`), the shape that tells it from a GUI agent chat's bare mark.
    static func templateImage(brand: String, size: CGFloat, fill: CGFloat = 0.86, terminal: Bool = false) -> NSImage? {
        guard let spec = spec(for: AgentBrandID(rawValue: brand))?.variant(forPointSize: Double(size)), size > 0 else { return nil }
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            if terminal {
                let radius = rect.width * terminalTileCornerShare
                context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
                context.setFillColor(CGColor(gray: 0, alpha: terminalTileAlpha))
                context.fillPath()
            }
            let side = rect.width * (terminal ? terminalTileMarkShare : fill)
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
