import AppKit
import CmuxNextDesign
import CmuxNextIcons

/// `EmptyState`: a quiet glyph (`symbol`, tertiary), a `title` (emphasized, secondary) and an
/// optional `message` (caption, tertiary, wrapping), centered, with the kit's padding.
final class AppSceneEmptyStateNSView: AppSceneNodeNSView {
    private let glyph = NSImageView()
    private let title = ChromeLabel(wrappingLabelWithString: "")
    private let message = ChromeLabel(wrappingLabelWithString: "")

    override init(id: String, node: AppSceneNode) {
        super.init(id: id, node: node)
        glyph.imageScaling = .scaleProportionallyDown
        title.font = Typography.bodyEmphasized
        message.font = Typography.caption
        for label in [title, message] { label.alignment = .center }
        [glyph, title, message].forEach(addSubview)
    }

    override func configure(_ node: AppSceneNode) {
        super.configure(node)
        glyph.image = node.string("symbol").map { NSImage.icon(symbol: $0, size: Metrics.iconSize) }
        glyph.isHidden = glyph.image == nil
        title.stringValue = node.string("title") ?? ""
        message.stringValue = node.string("message") ?? ""
        message.isHidden = message.stringValue.isEmpty
    }

    override func paint() {
        performWithTheme {
            glyph.contentTintColor = Palette.textTertiary
            title.textColor = Palette.textSecondary
            message.textColor = Palette.textTertiary
        }
    }

    private var pad: CGFloat { Metrics.space4 }

    /// The pieces' heights at `width`, top to bottom, with the gaps between them.
    private func parts(width: CGFloat) -> [(view: NSView, height: CGFloat)] {
        let inner = max(0, width - 2 * pad)
        var out: [(NSView, CGFloat)] = []
        if !glyph.isHidden { out.append((glyph, Metrics.iconSize)) }
        out.append((title, ceil(title.size(forWidth: inner).height)))
        if !message.isHidden { out.append((message, ceil(message.size(forWidth: inner).height))) }
        return out
    }

    override func contentHeight(width: CGFloat) -> CGFloat {
        let parts = parts(width: width)
        return parts.reduce(0) { $0 + $1.height } + Metrics.space2 * CGFloat(max(0, parts.count - 1)) + 2 * pad
    }

    override func layoutContent(in rect: CGRect) {
        var y = rect.minY + pad
        let inner = max(0, rect.width - 2 * pad)
        for (view, height) in parts(width: rect.width) {
            let width = view === glyph ? Metrics.iconSize : inner
            view.frame = CGRect(x: rect.minX + (rect.width - width) / 2, y: y, width: width, height: height).integral
            y += height + Metrics.space2
        }
    }
}
