import AppKit
import CmuxNextDesign
import CmuxNextIcons

/// `Menu`: a borderless pull-down, its `title` and a chevron in the title's ink (as AppKit's pull-down draws it), that opens its `menu` items (the same
/// entries as a context menu) under itself on a click; a pick sends `menu {path}`. Hover and press
/// paint the shared chrome fill, as a `Button` does.
final class AppSceneMenuNSView: AppSceneNodeNSView {
    private let title = ChromeLabel(labelWithString: "")
    private let chevron = NSImageView()
    private let fill = CALayer()
    private var pointerHover: PointerHover?
    private var isHovered = false
    /// The pull-down's target: menu items hold their target weakly.
    private var owner: AppSceneContextMenu?

    override init(id: String, node: AppSceneNode) {
        super.init(id: id, node: node)
        fill.actions = ["backgroundColor": NSNull(), "bounds": NSNull(), "position": NSNull()]
        fill.cornerCurve = .continuous
        layer?.addSublayer(fill)
        title.font = Typography.body
        title.maximumNumberOfLines = 1
        title.lineBreakMode = .byTruncatingTail
        chevron.image = Self.chevronImage()
        chevron.imageScaling = .scaleNone
        addSubview(title)
        addSubview(chevron)
        setAccessibilityElement(true)
        setAccessibilityRole(.menuButton)
        pointerHover = PointerHover(self) { [weak self] hovering in
            self?.isHovered = hovering
            self?.needsDisplay = true
        }
    }

    /// AppKit's pull-down chevron: the system `chevron.down` at 10 points in the emphasis weight, so its stroke
    /// covers whole pixels at 1x and it reaches its title's tone (the pack's 9-point glyph stays lighter; a 2x
    /// display hides it).
    private static func chevronImage() -> NSImage {
        NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: TypeScale.emphasis))
            ?? NSImage.icon(symbol: "chevron.down", size: 9, style: .solid)
    }

    /// The chevron's drawn size (its image's, placed on whole points so it stays crisp).
    private var chevronSize: CGSize { chevron.image?.size ?? CGSize(width: 9, height: 9) }

    override func configure(_ node: AppSceneNode) {
        super.configure(node)
        title.stringValue = node.string("title") ?? ""
        setAccessibilityLabel(node.string("title"))
        let entries = AppSceneContextMenu(items: node.props["menu"]?.arrayValue ?? []) { [weak self] path in
            self?.send("menu", ["path": .array(path.map { .number(Double($0)) })])
        }
        owner = entries
        menu = entries.menu
    }

    override var isTappable: Bool { false }

    override func mouseDown(with event: NSEvent) {
        guard !node.flag("disabled"), let menu else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.maxY + Metrics.space1), in: self)
    }

    override func accessibilityPerformPress() -> Bool { accessibilityPerformShowMenu() }

    override func accessibilityPerformShowMenu() -> Bool {
        guard !node.flag("disabled"), let menu else { return false }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.maxY + Metrics.space1), in: self)
        return true
    }

    override var contentNaturalWidth: CGFloat? {
        ceil(title.naturalSize.width) + Metrics.space1 + ceil(chevronSize.width) + 2 * Metrics.space2
    }

    override func contentHeight(width: CGFloat) -> CGFloat { max(ceil(title.naturalSize.height) + 2 * Metrics.space1, Metrics.iconSize + Metrics.space2) }

    override func layoutContent(in rect: CGRect) {
        fill.frame = rect
        fill.cornerRadius = Metrics.itemCornerRadius
        let inner = rect.insetBy(dx: Metrics.space2, dy: 0)
        let size = chevronSize
        chevron.frame = CGRect(x: (inner.maxX - size.width).rounded(.down), y: (rect.midY - size.height / 2).rounded(.down),
                               width: size.width, height: size.height)
        let height = ceil(title.naturalSize.height)
        title.frame = CGRect(x: inner.minX, y: rect.midY - height / 2, width: max(0, chevron.frame.minX - Metrics.space1 - inner.minX),
                             height: height).integral
    }

    override func paint() {
        title.textColor = Palette.textPrimary
        chevron.contentTintColor = Palette.textPrimary
        ChromeHover.paint(fill, ChromeHover.fillColor(ChromeHover.State(hovering: isHovered && !node.flag("disabled"), pressed: false)),
                          animated: window != nil, pressed: false)
    }
}
