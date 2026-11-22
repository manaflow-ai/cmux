import AppKit
import CmuxNextDesign
import CmuxNextIcons

/// A finished component in a state (`state` `loading`, `error` or `empty`, RFD 0009 slice 4), drawn
/// in the component's place as webviews' `SceneComponentStateView` draws it: a 16 point glyph (the
/// shared spinner; a warning triangle in the attention ink; a tray in tertiary), an EmptyState's
/// title, and one line of `stateMessage` (an EmptyState's `message` when it has none) in secondary,
/// centered. It has nothing to tap until the component draws again.
final class AppSceneStateNSView: AppSceneNodeNSView {
    private let spinner = StatusIndicatorView.spinner()
    private let glyph = NSImageView()
    private let title = ChromeLabel(labelWithString: "")
    private let message = ChromeLabel(labelWithString: "")
    private static let glyphSide: CGFloat = 16

    override init(id: String, node: AppSceneNode) {
        super.init(id: id, node: node)
        glyph.imageScaling = .scaleProportionallyDown
        title.font = Typography.bodyEmphasized
        message.font = Typography.caption
        for label in [title, message] {
            label.alignment = .center
            label.maximumNumberOfLines = 1
            label.lineBreakMode = .byTruncatingTail
        }
        [spinner, glyph, title, message].forEach(addSubview)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    private var state: AppSceneComponentState { node.componentState ?? .loading }

    override var isTappable: Bool { false }

    override func configure(_ node: AppSceneNode) {
        super.configure(node)
        let state = node.componentState ?? .loading
        spinner.isHidden = state != .loading
        spinner.spin(state == .loading && window != nil)
        glyph.isHidden = state == .loading
        glyph.image = state == .loading ? nil : NSImage.icon(symbol: state == .error ? "exclamationmark.triangle" : "tray", size: Self.glyphSide)
        let isEmptyState = node.type == .emptyState
        title.stringValue = isEmptyState ? node.string("title") ?? "" : ""
        title.isHidden = title.stringValue.isEmpty
        message.stringValue = node.string("stateMessage") ?? (isEmptyState ? node.string("message") : nil) ?? ""
        message.isHidden = message.stringValue.isEmpty
        setAccessibilityLabel([state.rawValue, title.stringValue, message.stringValue].filter { !$0.isEmpty }.joined(separator: ", "))
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        spinner.spin(state == .loading && window != nil)
    }

    override func paint() {
        performWithTheme {
            glyph.contentTintColor = state == .error ? Palette.attention : Palette.textTertiary
            title.textColor = Palette.textSecondary
            message.textColor = Palette.textSecondary
        }
    }

    /// The pieces top to bottom with their heights.
    private var parts: [(view: NSView, height: CGFloat)] {
        var out: [(NSView, CGFloat)] = [(state == .loading ? spinner : glyph, Self.glyphSide)]
        if !title.isHidden { out.append((title, ceil(title.naturalSize.height))) }
        if !message.isHidden { out.append((message, ceil(message.naturalSize.height))) }
        return out
    }

    override var contentNaturalWidth: CGFloat? {
        let labels = [title, message].filter { !$0.isHidden }.map { ceil($0.naturalSize.width) }
        return max(Self.glyphSide, labels.max() ?? 0) + 2 * Metrics.space2
    }

    override func contentHeight(width: CGFloat) -> CGFloat {
        let parts = parts
        let content = parts.reduce(0) { $0 + $1.height } + Metrics.space2 * CGFloat(max(0, parts.count - 1))
        return max(content + 2 * Metrics.space2, Metrics.iconSize + 2 * Metrics.space2)
    }

    override func layoutContent(in rect: CGRect) {
        let parts = parts
        let content = parts.reduce(0) { $0 + $1.height } + Metrics.space2 * CGFloat(max(0, parts.count - 1))
        var y = rect.midY - content / 2
        let inner = max(0, rect.width - 2 * Metrics.space2)
        for (view, height) in parts {
            let width = view === spinner || view === glyph ? Self.glyphSide : inner
            view.frame = CGRect(x: rect.minX + (rect.width - width) / 2, y: y, width: width, height: height).integral
            y += height + Metrics.space2
        }
    }
}
