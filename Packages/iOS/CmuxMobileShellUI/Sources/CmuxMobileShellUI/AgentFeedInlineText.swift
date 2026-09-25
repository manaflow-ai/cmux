#if os(iOS)
import Foundation
import SwiftUI
import UIKit

/// TextKit measures the same attributed text it displays, reserving room on
/// the last visible line for an accessible, inline expansion button. Taps on
/// rendered Markdown links open through SwiftUI's `openURL`, the same path
/// the Feed's other Markdown text uses.
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
    @Environment(\.openURL) private var openURL

    func makeUIView(context: Context) -> AgentFeedInlineTextView {
        AgentFeedInlineTextView()
    }

    func updateUIView(_ view: AgentFeedInlineTextView, context: Context) {
        _ = dynamicTypeSize
        view.configure(text: text, hasMoreText: hasMoreText, lineLimit: lineLimit,
                       itemID: itemID, textStyle: textStyle, monospaced: monospaced,
                       color: color, open: open, openURL: { openURL($0) })
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
    private var openURL: (@MainActor (URL) -> Void)?
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
        // The text view stays non-interactive so row gestures (context menu,
        // swipe actions) keep working; this recognizer begins only on a link.
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleLinkTap(_:))))
    }

    required init?(coder: NSCoder) { nil }

    func configure(text: String, hasMoreText: Bool, lineLimit: Int, itemID: String,
                   textStyle: UIFont.TextStyle, monospaced: Bool, color: UIColor,
                   open: @escaping @MainActor () -> Void,
                   openURL: @escaping @MainActor (URL) -> Void = { _ in }) {
        let preferred = UIFont.preferredFont(forTextStyle: textStyle, compatibleWith: traitCollection)
        let nextFont = monospaced
            ? UIFont.monospacedSystemFont(ofSize: preferred.pointSize, weight: .regular)
            : preferred
        self.open = open
        self.openURL = openURL
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
            // Markdown delimiters and link destinations are absent from the
            // rendered string. Truncate that string, preserving its attributes
            // and composed characters, then append an unformatted control.
            let characters = Array(complete.string)
            func preview(_ count: Int) -> NSMutableAttributedString {
                var prefix = String(characters.prefix(count))
                while prefix.last?.isWhitespace == true { prefix.removeLast() }
                let result = NSMutableAttributedString(attributedString: complete.attributedSubstring(
                    from: NSRange(location: 0, length: prefix.utf16.count)
                ))
                result.append(NSAttributedString(string: "… " + moreTitle,
                    attributes: [.font: font, .foregroundColor: textColor]))
                return result
            }
            var low = 0
            var high = characters.count
            while low < high {
                let middle = (low + high + 1) / 2
                if lineCount(preview(middle), width: width) <= lineLimit {
                    low = middle
                } else {
                    high = middle - 1
                }
            }
            let displayed = preview(low)
            let range = NSRange(location: displayed.length - moreTitle.utf16.count, length: moreTitle.utf16.count)
            displayed.addAttribute(.foregroundColor, value: tintColor ?? UIColor.systemBlue, range: range)
            textView.attributedText = displayed
            textView.accessibilityLabel = String(displayed.string.dropLast(moreTitle.count))
            linkRange = range
        } else {
            textView.attributedText = complete
            textView.accessibilityLabel = complete.string
            linkRange = nil
        }
        moreButton.isHidden = !needsExpansion
        measuredSize = textView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        measuredSize.width = width
        if needsExpansion {
            // Keep the inline button's 44-point hit target inside this view,
            // including a one-line preview shortened by the Mac.
            measuredSize.height = max(44, measuredSize.height + max(0, (44 - font.lineHeight) / 2))
        }
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
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .full
        options.failurePolicy = .returnPartiallyParsedIfPossible

        guard let markdown = try? AttributedString(markdown: value, options: options) else {
            return NSMutableAttributedString(
                string: value,
                attributes: [.font: font, .foregroundColor: textColor]
            )
        }

        let rendered = NSMutableAttributedString(string: "")
        var previousBlockID: Int?
        var previousListItemID: Int?
        for run in markdown.runs {
            let components = run.presentationIntent?.components ?? []
            let blockID = components.first?.identity
            if !rendered.string.isEmpty, blockID != previousBlockID,
               !rendered.string.hasSuffix("\n") {
                rendered.append(NSAttributedString(string: "\n",
                    attributes: [.font: font, .foregroundColor: textColor]))
            }
            previousBlockID = blockID

            var runFont = font
            var marker: String?
            var listItemID: Int?
            var ordinal: Int?
            var isCodeBlock = false
            var isQuote = false
            for component in components {
                switch component.kind {
                case .header:
                    runFont = Self.font(runFont, adding: .traitBold)
                case .codeBlock:
                    isCodeBlock = true
                case .listItem(let number) where listItemID == nil:
                    listItemID = component.identity
                    ordinal = number
                case .orderedList where marker == nil:
                    if let ordinal { marker = "\(ordinal). " }
                case .unorderedList where marker == nil:
                    marker = "• "
                case .blockQuote:
                    isQuote = true
                default:
                    break
                }
            }
            if listItemID != previousListItemID, let marker {
                rendered.append(NSAttributedString(string: marker,
                    attributes: [.font: font, .foregroundColor: textColor]))
            }
            previousListItemID = listItemID

            // Foundation supplies semantic block and inline intents. TextKit
            // needs concrete fonts and paragraph attributes to draw them.
            let intent = run.inlinePresentationIntent ?? []
            if isCodeBlock || intent.contains(.code) {
                runFont = UIFont.monospacedSystemFont(ofSize: font.pointSize, weight: .regular)
            }
            if intent.contains(.stronglyEmphasized) {
                runFont = Self.font(runFont, adding: .traitBold)
            }
            if intent.contains(.emphasized) {
                runFont = Self.font(runFont, adding: .traitItalic)
            }
            let part = NSMutableAttributedString(AttributedString(markdown[run.range]))
            let range = NSRange(location: 0, length: part.length)
            part.addAttributes([.font: runFont, .foregroundColor: textColor], range: range)
            if intent.contains(.strikethrough) {
                part.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            }
            if isCodeBlock || intent.contains(.code) {
                part.addAttribute(.backgroundColor, value: UIColor.secondarySystemBackground, range: range)
            }
            if isQuote || listItemID != nil {
                let paragraph = NSMutableParagraphStyle()
                paragraph.headIndent = font.pointSize
                if isQuote { paragraph.firstLineHeadIndent = font.pointSize }
                part.addAttribute(.paragraphStyle, value: paragraph, range: range)
            }
            rendered.append(part)
        }
        return rendered
    }

    private static func font(_ font: UIFont,
                             adding traits: UIFontDescriptor.SymbolicTraits) -> UIFont {
        let combined = font.fontDescriptor.symbolicTraits.union(traits)
        let descriptor = font.fontDescriptor.withSymbolicTraits(combined) ?? font.fontDescriptor
        return UIFont(descriptor: descriptor, size: font.pointSize)
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

    /// The Markdown link destination drawn at `point`, in this view's
    /// coordinates, or nil when the point is not on link text.
    func link(at point: CGPoint) -> URL? {
        guard let attributed = textView.attributedText, attributed.length > 0 else { return nil }
        let layout = textView.layoutManager
        let container = textView.textContainer
        layout.ensureLayout(for: container)
        let local = convert(point, to: textView)
        let glyph = layout.glyphIndex(for: local, in: container)
        // glyphIndex clamps to the nearest glyph; require a hit on it.
        let glyphRect = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        guard glyphRect.insetBy(dx: -4, dy: -4).contains(local) else { return nil }
        let index = layout.characterIndexForGlyph(at: glyph)
        guard index < attributed.length else { return nil }
        if let linkRange, NSLocationInRange(index, linkRange) { return nil }
        switch attributed.attribute(.link, at: index, effectiveRange: nil) {
        case let url as URL: return url
        case let string as String: return URL(string: string)
        default: return nil
        }
    }

    /// Opens the link at `point`. Returns whether a link was opened.
    @discardableResult
    func activateLink(at point: CGPoint) -> Bool {
        guard let url = link(at: point) else { return false }
        openURL?(url)
        return true
    }

    @objc private func handleLinkTap(_ recognizer: UITapGestureRecognizer) {
        activateLink(at: recognizer.location(in: self))
    }

    override func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        guard recognizer.view === self, recognizer is UITapGestureRecognizer else {
            return super.gestureRecognizerShouldBegin(recognizer)
        }
        return link(at: recognizer.location(in: self)) != nil
    }
}
#endif
