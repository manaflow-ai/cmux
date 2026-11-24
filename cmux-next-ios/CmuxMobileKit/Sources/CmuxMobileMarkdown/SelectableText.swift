#if os(iOS)
import CmuxMobileDesign
import SwiftUI
import UIKit

/// Transcript text drawn by a label until the reader holds a word to start editing the selection.
public struct SelectableText: View {
    private enum Content {
        case attributed(NSAttributedString)
        case plain(String, FontChoice, UIColor, CGFloat)
    }

    private enum FontChoice {
        case fixed(UIFont)
        case preferred(UIFont.TextStyle, monospaced: Bool)

        func font(for size: DynamicTypeSize) -> UIFont {
            switch self {
            case .fixed(let font): return font
            case let .preferred(style, monospaced):
                let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(size))
                let font = UIFont.preferredFont(forTextStyle: style, compatibleWith: traits)
                return monospaced ? .monospacedSystemFont(ofSize: font.pointSize, weight: .regular) : font
            }
        }
    }

    private let content: Content
    @Environment(\.dynamicTypeSize) private var typeSize

    public init(_ text: NSAttributedString) {
        content = .attributed(text)
    }

    public init(_ text: String, font: UIFont? = nil, color: UIColor = .label, lineSpacing: CGFloat = 0) {
        content = .plain(text, font.map(FontChoice.fixed) ?? .preferred(.body, monospaced: false), color, lineSpacing)
    }

    public init(_ text: String, textStyle: UIFont.TextStyle, monospaced: Bool = false, color: UIColor = .label, lineSpacing: CGFloat = 0) {
        content = .plain(text, .preferred(textStyle, monospaced: monospaced), color, lineSpacing)
    }

    private var attributedText: NSAttributedString {
        switch content {
        case .attributed(let text): return text
        case let .plain(text, font, color, spacing):
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = spacing
            return NSAttributedString(string: text, attributes: [
                .font: font.font(for: typeSize),
                .foregroundColor: color, .paragraphStyle: paragraph,
            ])
        }
    }

    public var body: some View {
        let text = attributedText
        let firstFont = text.length > 0 ? text.attribute(.font, at: 0, effectiveRange: nil) as? UIFont : nil
        let baseline = firstFont?.ascender ?? 0
        SelectableLabel(text: text)
            .alignmentGuide(.firstTextBaseline) { _ in baseline }
    }
}

private struct SelectableLabel: UIViewRepresentable {
    let text: NSAttributedString
    @Environment(\.selectionMenuRows) private var menuRows
    @Environment(\.openURL) private var openURL
    @Environment(\.lineLimit) private var lineLimit
    @Environment(\.multilineTextAlignment) private var alignment
    @Environment(\.truncationMode) private var truncation
    @Environment(\.layoutDirection) private var direction

    init(text: NSAttributedString) { self.text = text }

    func makeUIView(context: Context) -> SelectableLabelHost {
        SelectableLabelHost(frame: .zero)
    }

    func updateUIView(_ host: SelectableLabelHost, context: Context) {
        host.openLink = { openURL($0) }
        host.selection.extraMenu = { [menuRows] label in menuRows?(label) ?? [] }
        let textAlignment: NSTextAlignment = switch alignment {
        case .leading: .natural
        case .center: .center
        case .trailing: direction == .rightToLeft ? .left : .right
        @unknown default: .natural
        }
        let lineBreak: NSLineBreakMode = switch truncation {
        case .head: .byTruncatingHead
        case .middle: .byTruncatingMiddle
        case .tail: .byTruncatingTail
        @unknown default: .byTruncatingTail
        }
        host.update(text, lineLimit: lineLimit, lineBreak: lineBreak, alignment: textAlignment)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView host: SelectableLabelHost, context: Context) -> CGSize? {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? CGFloat.greatestFiniteMagnitude
        guard width > 0 else { return .zero }
        let size = host.label.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: min(ceil(size.width), width), height: ceil(size.height))
    }

    static func dismantleUIView(_ host: SelectableLabelHost, coordinator: ()) {
        host.selection.end()
    }
}

private final class SelectableLabelHost: UIView {
    let label = UILabel()
    lazy var selection = InPlaceTextSelection(host: self) { [weak label] in label.map { [$0] } ?? [] }
    var openLink: ((URL) -> Void)?
    private let tapLink = UITapGestureRecognizer()
    private var displayed: NSAttributedString?

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.numberOfLines = 0
        label.isAccessibilityElement = true
        addSubview(label)
        tapLink.addTarget(self, action: #selector(linkTapped))
        tapLink.require(toFail: selection.press)
        addGestureRecognizer(tapLink)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        if selection.isSelecting, label.frame.width != bounds.width { selection.end() }
        label.frame = bounds
    }

    override var forFirstBaselineLayout: UIView { label }
    override var forLastBaselineLayout: UIView { label }

    func update(_ text: NSAttributedString, lineLimit: Int?, lineBreak: NSLineBreakMode, alignment: NSTextAlignment) {
        if displayed?.isEqual(to: text) != true {
            // The streaming tail can grow under a held finger. The overlay keeps the reader's
            // range while the underlying label takes appended text. A reused row ends selection.
            if selection.isSelecting, let displayed, !text.string.hasPrefix(displayed.string) {
                selection.end()
            }
            displayed = text
            label.attributedText = text
            updateLinks(text)
        }
        label.numberOfLines = lineLimit ?? 0
        label.lineBreakMode = lineLimit == nil ? .byWordWrapping : lineBreak
        if label.textAlignment != alignment { label.textAlignment = alignment }
    }

    private func updateLinks(_ text: NSAttributedString) {
        var actions: [UIAccessibilityCustomAction] = []
        text.enumerateAttribute(NativeMarkdownLayout.linkKey, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            guard let url = value as? URL else { return }
            let title = (text.string as NSString).substring(with: range)
            actions.append(UIAccessibilityCustomAction(name: String(localized: "Open \(title)")) { [weak self] _ in
                self?.openLink?(url)
                return true
            })
        }
        label.accessibilityCustomActions = actions
        label.accessibilityTraits = actions.isEmpty ? .staticText : [.staticText, .link]
        tapLink.isEnabled = !actions.isEmpty
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === tapLink { return !selection.isSelecting && link(at: tapLink) != nil }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }

    @objc private func linkTapped() {
        if let url = link(at: tapLink) { openLink?(url) }
    }

    private func link(at recognizer: UIGestureRecognizer) -> URL? {
        NativeMarkdownView.link(in: label, at: recognizer.location(in: label), asDrawn: true)
    }
}
#endif
