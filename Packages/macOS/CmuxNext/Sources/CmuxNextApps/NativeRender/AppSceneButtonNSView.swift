import AppKit
import CmuxNextDesign

/// `Button`: its `title` (primary, or danger when `destructive`), or its children laid out in a row
/// as the label. A click sends `tap`; hover and press paint the shared chrome fill.
final class AppSceneButtonNSView: AppSceneNodeNSView {
    private let title = ChromeLabel(labelWithString: "")
    private let fill = CALayer()
    private var pointerHover: PointerHover?
    private var isHovered = false
    private var isPressed = false

    override init(id: String, node: AppSceneNode) {
        super.init(id: id, node: node)
        fill.actions = ["backgroundColor": NSNull(), "bounds": NSNull(), "position": NSNull()]
        fill.cornerCurve = .continuous
        layer?.addSublayer(fill)
        title.maximumNumberOfLines = 1
        title.lineBreakMode = .byTruncatingTail
        addSubview(title)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        pointerHover = PointerHover(self) { [weak self] hovering in
            self?.isHovered = hovering
            self?.needsDisplay = true
        }
    }

    override var isTappable: Bool { !node.flag("disabled") }

    override func configure(_ node: AppSceneNode) {
        super.configure(node)
        title.stringValue = node.string("title") ?? ""
        title.font = Typography.body
        title.isHidden = node.string("title") == nil
        setAccessibilityLabel(node.string("title") ?? node.string("help"))
    }

    /// Children label the button only when it has no title.
    private var labelChildren: [AppSceneNodeNSView] { title.isHidden ? childViews : [] }

    override var contentNaturalWidth: CGFloat? {
        if !title.isHidden { return ceil(title.naturalSize.width) + 2 * Metrics.space2 }
        var total: CGFloat = 0
        for child in labelChildren {
            guard let width = child.naturalWidth else { return nil }
            total += width
        }
        return total + Metrics.space2 * CGFloat(max(0, labelChildren.count - 1)) + 2 * Metrics.space2
    }

    override func contentHeight(width: CGFloat) -> CGFloat {
        let label = title.isHidden ? (labelChildren.map { $0.height(width: width) }.max() ?? 0) : ceil(title.naturalSize.height)
        return max(label + 2 * Metrics.space1, Metrics.iconSize + Metrics.space2)
    }

    override func layoutContent(in rect: CGRect) {
        fill.frame = rect
        fill.cornerRadius = Metrics.itemCornerRadius
        let inner = rect.insetBy(dx: Metrics.space2, dy: 0)
        if !title.isHidden {
            let height = ceil(title.naturalSize.height)
            title.frame = CGRect(x: inner.minX, y: rect.midY - height / 2, width: inner.width, height: height).integral
            return
        }
        var x = inner.minX
        for child in labelChildren {
            let width = child.naturalWidth ?? inner.width
            let height = child.height(width: width)
            child.frame = CGRect(x: x, y: rect.midY - height / 2, width: width, height: height).integral
            x += width + Metrics.space2
        }
    }

    override func paint() {
        performWithTheme {
            title.textColor = node.flag("destructive") ? Palette.danger : Palette.textPrimary
            let state = ChromeHover.State(hovering: isHovered && isTappable, pressed: isPressed)
            ChromeHover.paint(fill, ChromeHover.fillColor(state), animated: window != nil, pressed: isPressed)
        }
    }

    override func pressChanged(_ pressed: Bool) {
        isPressed = pressed
        needsDisplay = true
    }
}
