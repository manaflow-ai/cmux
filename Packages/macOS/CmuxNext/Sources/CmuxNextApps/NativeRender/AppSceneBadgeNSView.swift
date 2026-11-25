import AppKit
import CmuxNextDesign

/// `Badge`: `text` on a capsule of its `tone` (``AppSceneBadgeLabel``).
final class AppSceneBadgeNSView: AppSceneNodeNSView {
    private let badge = AppSceneBadgeLabel()

    override init(id: String, node: AppSceneNode) {
        super.init(id: id, node: node)
        addSubview(badge)
    }

    override func configure(_ node: AppSceneNode) {
        super.configure(node)
        badge.configure(text: node.string("text"), tone: node.props["tone"])
    }

    override func paint() { badge.applyColors() }

    override var contentNaturalWidth: CGFloat? { badge.isHidden ? 0 : badge.fittingSize.width }
    override func contentHeight(width: CGFloat) -> CGFloat { badge.isHidden ? 0 : badge.fittingSize.height }
    override func layoutContent(in rect: CGRect) {
        let size = badge.fittingSize
        badge.frame = CGRect(x: rect.minX, y: rect.midY - size.height / 2, width: min(size.width, rect.width), height: size.height).integral
    }
}
