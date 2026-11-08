import AppKit
import CmuxNextDesign

/// `Panel`: a group on the app's card surface with the card's padding and radius, and an optional
/// `title` in the caption style. `glass` (the default) is the sidebar cards' surface (`CardSurfaceView`,
/// tinted with the theme); `card` is the opaque elevated fill with a separator hairline. Children
/// stack vertically with `spacing` (the kit's `space2` by default).
final class AppScenePanelNSView: AppSceneNodeNSView {
    private let surface = CardSurfaceView(cornerRadius: Metrics.surfaceCornerRadius)
    private let card = CALayer()
    private let title = ChromeLabel(labelWithString: "")
    private let content = PanelContentView()

    override init(id: String, node: AppSceneNode) {
        super.init(id: id, node: node)
        surface.takesThemeTint = true
        card.cornerCurve = .continuous
        card.actions = ["backgroundColor": NSNull(), "bounds": NSNull(), "position": NSNull(), "borderColor": NSNull()]
        layer?.addSublayer(card)
        title.font = Typography.caption
        title.maximumNumberOfLines = 1
        [surface, title, content].forEach(addSubview)
    }

    override var childHost: NSView { content }

    private var isCard: Bool { node.string("style") == "card" }
    private var spacing: CGFloat { node.number("spacing").map { CGFloat($0) } ?? Metrics.space2 }
    private var hasTitle: Bool { !(node.string("title") ?? "").isEmpty }
    private var outer: CGFloat { Metrics.space3 }
    private var inner: CGFloat { Metrics.space3 }

    override func configure(_ node: AppSceneNode) {
        super.configure(node)
        title.stringValue = node.string("title") ?? ""
        title.isHidden = !hasTitle
        surface.isHidden = isCard
        card.isHidden = !isCard
    }

    override func paint() {
        performWithTheme {
            title.textColor = Palette.textSecondary
            // An inline card on the sidebar: a translucent tint over the sidebar, never an opaque fill.
            card.backgroundColor = Palette.hoverFill.cgColor
            card.borderColor = Palette.separator.cgColor
        }
    }

    /// The pieces stacked inside the card: the title, then each child.
    private func rows(width: CGFloat) -> [(view: NSView, height: CGFloat)] {
        let inside = max(0, width - 2 * outer - 2 * inner)
        var out: [(NSView, CGFloat)] = []
        if hasTitle { out.append((title, ceil(title.naturalSize.height))) }
        for child in childViews { out.append((child, child.height(width: min(child.naturalWidth ?? inside, inside)))) }
        return out
    }

    override func contentHeight(width: CGFloat) -> CGFloat {
        let rows = rows(width: width)
        return rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, rows.count - 1)) + 2 * inner
    }

    override func layoutContent(in rect: CGRect) {
        let box = rect.insetBy(dx: outer, dy: 0)
        surface.frame = box
        surface.cornerRadius = Metrics.surfaceCornerRadius
        content.frame = box
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        card.frame = box
        card.cornerRadius = Metrics.surfaceCornerRadius
        card.borderWidth = 1
        CATransaction.commit()
        let inside = max(0, box.width - 2 * inner)
        var y = inner
        for (view, height) in rows(width: rect.width) {
            let width = (view as? AppSceneNodeNSView)?.naturalWidth.map { min($0, inside) } ?? inside
            let frame = CGRect(x: inner, y: y, width: width, height: height)
            // The title is this view's subview; children live in `content`, whose origin is the card's.
            view.frame = view === title ? frame.offsetBy(dx: box.minX, dy: box.minY) : frame
            y += height + spacing
        }
    }
}

/// The panel's children's parent, top-down like the rest of the renderer.
private final class PanelContentView: NSView {
    nonisolated override var isFlipped: Bool { true }
}
