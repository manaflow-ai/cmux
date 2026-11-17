import AppKit
import CmuxNextDesign

/// `Text`: a chrome label in the chrome type scale (`font`: a text style name or a point size;
/// `weight`, `italic`, `monospaced`, `strikethrough`, `fontDesign` `rounded`/`serif`/`monospaced`), the `color` tone
/// (primary by default), `lineLimit` lines (no limit by default) and `truncation`. With a `date` it is a host-ticking
/// Text (`dateStyle`, ``AppSceneDateText``): its string comes from the date and ``AppSceneClock`` ticks it.
final class AppSceneTextNSView: AppSceneNodeNSView {
    let label = ChromeLabel(wrappingLabelWithString: "")

    override init(id: String, node: AppSceneNode) {
        super.init(id: id, node: node)
        addSubview(label)
    }

    /// The ticking date this Text shows, if any.
    private var dateText: AppSceneDateText?

    /// The text the label shows now: the date's at this second, or the app's `text`.
    private var shownText: String { dateText?.text(at: Date()) ?? node.string("text") ?? "" }

    override func configure(_ node: AppSceneNode) {
        super.configure(node)
        dateText = AppSceneDateText(node)
        updateTicking()
        label.stringValue = shownText
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
        updateTicking()
        if window != nil {
            if dateText != nil { label.stringValue = shownText }
            performWithTheme { paintContent() }
        }
    }

    /// The scene clock this Text ticks on while it is in a window.
    private weak var clock: AppSceneClock?

    /// Ticks only while a ticking Text is in a window, on its mounted scene's clock.
    private func updateTicking() {
        var host = superview
        while let view = host, !(view is AppSceneNativeView) { host = view.superview }
        let next = dateText != nil && window != nil ? (host as? AppSceneNativeView)?.clock : nil
        guard next !== clock else { return }
        clock?.remove(self)
        clock = next
        next?.add(self)
    }

    /// One second of the shared clock: a new string re-lays the scene only when its length changes.
    func tick(_ now: Date) {
        guard let dateText else { return }
        let text = dateText.text(at: now)
        guard text != label.stringValue else { return }
        let resize = text.count != label.stringValue.count
        label.stringValue = text
        performWithTheme { paintContent() }
        guard resize else { return }
        var view: NSView? = self
        while let current = view {
            current.needsLayout = true
            current.invalidateIntrinsicContentSize()
            if current is AppSceneNativeView { break }
            view = current.superview
        }
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
            string: label.stringValue,
            attributes: [
                .font: label.font ?? Typography.body,
                .foregroundColor: color,
                .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                .paragraphStyle: paragraph,
            ]
        )
    }

    override var contentNaturalWidth: CGFloat? { ceil(label.naturalSize.width) }

    override func contentHeight(width: CGFloat) -> CGFloat { ceil(label.size(forWidth: width).height) }

    override func layoutContent(in rect: CGRect) { label.frame = rect }

    /// The first line's baseline below the node's top (an HStack's `firstTextBaseline`).
    override func firstBaseline(width: CGFloat) -> CGFloat? {
        guard let font = label.font else { return nil }
        return padding.top + ceil(font.ascender)
    }

    /// The last line's baseline above the node's bottom (an HStack's `lastTextBaseline`).
    override func lastBaselineFromBottom(width: CGFloat) -> CGFloat? {
        guard let font = label.font else { return nil }
        return padding.bottom + ceil(-font.descender)
    }

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
        let design = Self.design(node)
        if chosen != nil || design != .default {
            let fallback: NSFont.Weight = node.string("font") == "headline" ? .semibold : .regular
            font = Typography.system(design, size: base.pointSize, weight: chosen ?? fallback)
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

    /// `fontDesign` (`rounded`, `serif`, `monospaced`), else `monospaced`; the type scale keeps the size.
    static func design(_ node: AppSceneNode) -> Typography.Design {
        switch node.string("fontDesign") {
        case "rounded": .rounded
        case "serif": .serif
        case "monospaced": .monospaced
        default: node.flag("monospaced") ? .monospaced : .default
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
