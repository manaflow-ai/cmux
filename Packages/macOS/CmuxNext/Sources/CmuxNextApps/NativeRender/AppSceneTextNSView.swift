import AppKit
import CmuxNextDesign

/// `Text`: a chrome label in the chrome type scale (`font`: a text style name or a point size;
/// `weight`, `italic`, `monospaced`, `strikethrough`), the `color` tone (primary by default), `lineLimit` lines (no
/// limit by default) and `truncation`.
final class AppSceneTextNSView: AppSceneNodeNSView {
    let label = ChromeLabel(wrappingLabelWithString: "")

    override init(id: String, node: AppSceneNode) {
        super.init(id: id, node: node)
        // Its own layer: a content transition rolls or crossfades the label alone.
        label.wantsLayer = true
        addSubview(label)
    }

    override func configure(_ node: AppSceneNode) {
        let before = label.stringValue
        super.configure(node)
        let text = node.string("text") ?? ""
        if text != before, window != nil, !before.isEmpty { transitionContent(from: before, to: text) }
        label.stringValue = text
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
    /// `strikethrough` draws a line through the text in the same color (a done reminder).
    private func paintContent() {
        let color = node.props["color"]?.sceneColor ?? Palette.textPrimary
        label.textColor = color
        guard node.flag("strikethrough") else { return }
        // A one-line label truncates in its paragraph; a wrapping one wraps there and the cell
        // truncates its last line. (Turning it off needs nothing: configure sets the plain string.)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = label.maximumNumberOfLines == 1 ? label.lineBreakMode : .byWordWrapping
        label.attributedStringValue = NSAttributedString(
            string: node.string("text") ?? "",
            attributes: [
                .font: label.font ?? Typography.body,
                .foregroundColor: color,
                .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                .paragraphStyle: paragraph,
            ]
        )
    }

    /// `contentTransition` on a text already on screen: `numericText` rolls the new value in (up when
    /// it grew, down when it shrank), `opacity` crossfades it, behind the sidebar's motion gate (Reduce
    /// Motion crossfades; motion off draws the new value at once).
    private func transitionContent(from before: String, to after: String) {
        switch node.string("contentTransition") {
        case "numericText": Motion.sidebar.rollInPlace(label.layer, upward: Self.grew(from: before, to: after))
        case "opacity": Motion.sidebar.crossfadeInPlace(label.layer)
        default: break
        }
    }

    /// Whether `after` reads as a larger number than `before` (digits only, so "9:41" and "12°" compare
    /// by their digits); a text that is not a number rolls up.
    static func grew(from before: String, to after: String) -> Bool {
        let digits = { (text: String) in Double(text.filter(\.isNumber)) }
        guard let old = digits(before), let new = digits(after) else { return true }
        return new >= old
    }

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
