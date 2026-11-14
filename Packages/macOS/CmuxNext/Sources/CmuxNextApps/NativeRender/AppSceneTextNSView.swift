import AppKit
import CmuxNextDesign

/// `Text`: a chrome label in the chrome type scale (`font`: a text style name or a point size;
/// `weight`, `italic`, `monospaced`), the `color` tone (primary by default), `lineLimit` lines (no
/// limit by default) and `truncation`.
final class AppSceneTextNSView: AppSceneNodeNSView {
    let label = ChromeLabel(wrappingLabelWithString: "")

    override init(id: String, node: AppSceneNode) {
        super.init(id: id, node: node)
        addSubview(label)
    }

    override func configure(_ node: AppSceneNode) {
        super.configure(node)
        label.stringValue = node.string("text") ?? ""
        label.font = Self.font(node)
        let lines = node.number("lineLimit").map { max(1, Int($0)) } ?? 0
        label.maximumNumberOfLines = lines
        label.lineBreakMode = switch node.string("truncation") {
        case "head": .byTruncatingHead
        case "middle": .byTruncatingMiddle
        default: lines == 0 ? .byWordWrapping : .byTruncatingTail
        }
        setAccessibilityElement(false)
        performWithTheme { paintContent() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { performWithTheme { paintContent() } }
    }

    override func paint() {
        performWithTheme { paintContent() }
    }

    /// The label's color from the theme in scope, on configure and on each draw.
    private func paintContent() { label.textColor = node.props["color"]?.sceneColor ?? Palette.textPrimary }

    override var contentNaturalWidth: CGFloat? { ceil(label.naturalSize.width) }

    override func contentHeight(width: CGFloat) -> CGFloat { ceil(label.size(forWidth: width).height) }

    override func layoutContent(in rect: CGRect) { label.frame = rect }

    /// The node's font: a text style name (chrome sizes for body, caption and headline) or a point size.
    @MainActor
    static func font(_ node: AppSceneNode) -> NSFont {
        let base: NSFont = switch node.props["font"] {
        case .number(let size)?: Typography.system(.default, size: CGFloat(max(6, min(size, 64))))
        case .string(let name)?: textStyle(name)
        default: Typography.body
        }
        var font = base
        let chosen = Self.weight(node.string("weight"))
        let monospaced = node.flag("monospaced")
        if chosen != nil || monospaced {
            let fallback: NSFont.Weight = node.string("font") == "headline" ? .semibold : .regular
            font = Typography.system(monospaced ? .monospaced : .default, size: base.pointSize, weight: chosen ?? fallback)
        }
        if node.flag("italic") { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
        return font
    }

    @MainActor
    private static func textStyle(_ name: String) -> NSFont {
        switch name {
        case "largeTitle": NSFont.preferredFont(forTextStyle: .largeTitle)
        case "title": NSFont.preferredFont(forTextStyle: .title1)
        case "title2": NSFont.preferredFont(forTextStyle: .title2)
        case "title3": NSFont.preferredFont(forTextStyle: .title3)
        case "headline": Typography.header
        case "subheadline": NSFont.preferredFont(forTextStyle: .subheadline)
        case "callout": NSFont.preferredFont(forTextStyle: .callout)
        case "caption": Typography.caption
        case "caption2": NSFont.preferredFont(forTextStyle: .caption2)
        default: Typography.body
        }
    }

    private static func weight(_ name: String?) -> NSFont.Weight? {
        switch name {
        case "ultraLight": .ultraLight
        case "thin": .thin
        case "light": .light
        case "regular": .regular
        case "medium": .medium
        case "semibold": .semibold
        case "bold": .bold
        case "heavy": .heavy
        case "black": .black
        default: nil
        }
    }
}
