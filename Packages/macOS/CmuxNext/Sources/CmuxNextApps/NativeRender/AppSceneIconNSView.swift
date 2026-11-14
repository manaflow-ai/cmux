import AppKit
import CmuxNextDesign
import CmuxNextIcons

/// `Icon`: a pack icon or SF Symbol (`symbol`) at `size` points (the small icon size by default), in
/// the `color` tone (secondary by default).
final class AppSceneIconNSView: AppSceneNodeNSView {
    private let image = NSImageView()
    private var side: CGFloat { node.number("size").map { CGFloat($0) } ?? Metrics.smallIconSize }

    override init(id: String, node: AppSceneNode) {
        super.init(id: id, node: node)
        image.imageScaling = .scaleProportionallyDown
        addSubview(image)
    }

    override func configure(_ node: AppSceneNode) {
        super.configure(node)
        image.image = NSImage.icon(symbol: node.string("symbol") ?? "circle", size: side)
    }

    override func paint() {
        performWithTheme { image.contentTintColor = node.props["color"]?.sceneColor ?? Palette.textSecondary }
    }

    override var contentNaturalWidth: CGFloat? { side }
    override func contentHeight(width: CGFloat) -> CGFloat { side }
    override func layoutContent(in rect: CGRect) {
        image.frame = CGRect(x: rect.minX, y: rect.midY - side / 2, width: side, height: side).integral
    }
}
