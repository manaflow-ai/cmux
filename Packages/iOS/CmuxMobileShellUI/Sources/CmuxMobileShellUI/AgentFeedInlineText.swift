#if os(iOS)
import SwiftUI
import UIKit

/// TextKit measures the same attributed text it displays, reserving room on
/// the last visible line for an accessible, inline expansion button.
struct AgentFeedInlineText: UIViewRepresentable {
    let text: String
    let hasMoreText: Bool
    let lineLimit: Int
    let itemID: String
    var textStyle: UIFont.TextStyle = .subheadline
    var monospaced = false
    var color: UIColor = .label
    let open: @MainActor () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    func makeUIView(context: Context) -> AgentFeedInlineTextView {
        AgentFeedInlineTextView()
    }

    func updateUIView(_ view: AgentFeedInlineTextView, context: Context) {
        _ = dynamicTypeSize
        view.configure(text: text, hasMoreText: hasMoreText, lineLimit: lineLimit,
                       itemID: itemID, textStyle: textStyle, monospaced: monospaced,
                       color: color, open: open)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: AgentFeedInlineTextView,
                      context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        return uiView.measure(width: width)
    }
}

final class AgentFeedInlineTextView: UIView {
    private let textView = UITextView()
    private let moreButton = UIButton(type: .custom)
    private var source = ""
    private var hasMoreText = false
    private var lineLimit = 8
    private var font = UIFont.preferredFont(forTextStyle: .subheadline)
    private var textColor = UIColor.label
    private var open: (@MainActor () -> Void)?
    private var measuredWidth: CGFloat = -1
    private var measuredSize: CGSize = .zero
    private var linkRange: NSRange?
    private let moreTitle = String(localized: "mobile.agentFeed.fullText.seeMore",
                                   defaultValue: "See more", bundle: .module)

    override init(frame: CGRect) {
        super.init(frame: frame)
        textView.isEditable = false
        textView.isSelectable = false
        textView.isScrollEnabled = false
        textView.isUserInteractionEnabled = false
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        addSubview(textView)
        moreButton.accessibilityLabel = moreTitle
        moreButton.addTarget(self, action: #selector(expand), for: .touchUpInside)
        addSubview(moreButton)
    }

    required init?(coder: NSCoder) { nil }

    func configure(text: String, hasMoreText: Bool, lineLimit: Int, itemID: String,
                   textStyle: UIFont.TextStyle, monospaced: Bool, color: UIColor,
                   open: @escaping @MainActor () -> Void) {
        let preferred = UIFont.preferredFont(forTextStyle: textStyle, compatibleWith: traitCollection)
        let nextFont = monospaced
            ? UIFont.monospacedSystemFont(ofSize: preferred.pointSize, weight: .regular)
            : preferred
        self.open = open
        moreButton.accessibilityIdentifier = "MobileAgentFeedFullText-\(itemID)"
        guard source != text || self.hasMoreText != hasMoreText || self.lineLimit != lineLimit
                || font != nextFont || textColor != color else { return }
        source = text
        self.hasMoreText = hasMoreText
        self.lineLimit = lineLimit
        font = nextFont
        textColor = color
        measuredWidth = -1
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    func measure(width: CGFloat) -> CGSize {
        if measuredWidth == width { return measuredSize }
        measuredWidth = width
        let complete = attributed(source)
        let needsExpansion = hasMoreText || lineCount(complete, width: width) > lineLimit
        if needsExpansion {
            let characters = Array(source)
            var low = 0
            var high = characters.count
            while low < high {
                let middle = (low + high + 1) / 2
                let prefix = String(characters.prefix(middle)).trimmingCharacters(in: .whitespacesAndNewlines)
                if lineCount(attributed(prefix + "… " + moreTitle), width: width) <= lineLimit {
                    low = middle
                } else {
                    high = middle - 1
                }
            }
            let prefix = String(characters.prefix(low)).trimmingCharacters(in: .whitespacesAndNewlines)
            let displayed = attributed(prefix + "… " + moreTitle)
            let range = NSRange(location: (prefix + "… ").utf16.count, length: moreTitle.utf16.count)
            displayed.addAttribute(.foregroundColor, value: tintColor ?? UIColor.systemBlue, range: range)
            textView.attributedText = displayed
            textView.accessibilityLabel = prefix + "…"
            linkRange = range
        } else {
            textView.attributedText = complete
            textView.accessibilityLabel = source
            linkRange = nil
        }
        moreButton.isHidden = !needsExpansion
        measuredSize = textView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        measuredSize.width = width
        return measuredSize
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0 else { return }
        _ = measure(width: bounds.width)
        textView.frame = bounds
        textView.layoutManager.ensureLayout(for: textView.textContainer)
        if let linkRange {
            let glyphs = textView.layoutManager.glyphRange(forCharacterRange: linkRange, actualCharacterRange: nil)
            let rect = textView.layoutManager.boundingRect(forGlyphRange: glyphs, in: textView.textContainer)
            moreButton.frame = CGRect(x: max(0, rect.midX - max(44, rect.width) / 2),
                                      y: max(0, rect.midY - 22),
                                      width: max(44, rect.width), height: 44)
        }
    }

    private func attributed(_ value: String) -> NSMutableAttributedString {
        NSMutableAttributedString(string: value, attributes: [.font: font, .foregroundColor: textColor])
    }

    private func lineCount(_ value: NSAttributedString, width: CGFloat) -> Int {
        let storage = NSTextStorage(attributedString: value)
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        layout.ensureLayout(for: container)
        var count = 0
        layout.enumerateLineFragments(forGlyphRange: layout.glyphRange(for: container)) { _, _, _, _, stop in
            count += 1
            if count > self.lineLimit { stop.pointee = true }
        }
        if layout.extraLineFragmentTextContainer != nil { count += 1 }
        return count
    }

    @objc private func expand() { open?() }
}
#endif
