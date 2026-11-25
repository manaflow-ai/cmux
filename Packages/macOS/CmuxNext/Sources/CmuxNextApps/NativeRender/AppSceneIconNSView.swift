import AppKit
import CmuxNextDesign
import CmuxNextIcons

/// `Icon`: a pack icon or SF Symbol (`symbol`) at `size` points (the small icon size by default), in
/// the `color` tone (secondary by default). `symbolRendering` `hierarchical`, `palette` or
/// `multicolor` draws the system SF Symbol with that `NSImage.SymbolConfiguration` (hierarchical in
/// the tone, palette in `symbolColors` (1 to 3 tones or hex), multicolor in the symbol's own colors
/// with the tone where it has none); a name that is not a system symbol, and `monochrome`, draw as before.
final class AppSceneIconNSView: AppSceneNodeNSView {
    private let image = NSImageView()
    private var side: CGFloat { node.number("size").map { CGFloat($0) } ?? Metrics.smallIconSize }
    /// What the drawn system symbol was made from, so a repaint with the same inputs keeps the image.
    private var drawnSymbol: (name: String, mode: String, side: CGFloat, colors: [NSColor])?

    override init(id: String, node: AppSceneNode) {
        super.init(id: id, node: node)
        image.imageScaling = .scaleProportionallyDown
        addSubview(image)
    }

    /// The rendering mode that needs the system symbol, or nil for the template image.
    private var colorMode: String?

    override func configure(_ node: AppSceneNode) {
        super.configure(node)
        drawnSymbol = nil
        colorMode = node.string("symbolRendering").flatMap { mode in
            guard ["hierarchical", "palette", "multicolor"].contains(mode), let name = node.string("symbol"),
                  NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil else { return nil }
            return mode
        }
        if colorMode == nil { image.image = NSImage.icon(symbol: node.string("symbol") ?? "circle", size: side) }
    }

    override func paint() {
        let tint = node.props["color"]?.sceneColor ?? Palette.textSecondary
        guard let mode = colorMode, let name = node.string("symbol") else {
            image.contentTintColor = tint
            return
        }
        // 1 to 3 colors, all valid, else none (the tint), as the web renderer and the builder refuse.
        let given = node.props["symbolColors"]?.arrayValue ?? []
        let parsed = given.compactMap(\.sceneColor)
        let palette = (1...3).contains(given.count) && parsed.count == given.count ? parsed : []
        let colors = mode == "palette" && !palette.isEmpty ? palette : [tint]
        image.contentTintColor = nil
        if let drawn = drawnSymbol, drawn.name == name, drawn.mode == mode, drawn.side == side, drawn.colors == colors { return }
        var config = NSImage.SymbolConfiguration(pointSize: side, weight: .regular)
        switch mode {
        case "hierarchical": config = config.applying(NSImage.SymbolConfiguration(hierarchicalColor: tint))
        case "palette": config = config.applying(NSImage.SymbolConfiguration(paletteColors: colors))
        // The tone first, so a layer the symbol leaves uncolored (a cloud) takes it, not black.
        default: config = config.applying(NSImage.SymbolConfiguration(paletteColors: colors)).applying(.preferringMulticolor())
        }
        image.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        drawnSymbol = (name, mode, side, colors)
    }

    override var contentNaturalWidth: CGFloat? { side }
    override func contentHeight(width: CGFloat) -> CGFloat { side }
    override func layoutContent(in rect: CGRect) {
        image.frame = CGRect(x: rect.minX, y: rect.midY - side / 2, width: side, height: side).integral
    }
}
