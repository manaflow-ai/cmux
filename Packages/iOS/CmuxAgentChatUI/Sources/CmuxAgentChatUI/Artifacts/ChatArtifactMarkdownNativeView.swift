#if os(iOS)
import Foundation
import UIKit

/// Document-level Markdown rendered with UIKit and Foundation's native parser.
@MainActor
final class ChatArtifactMarkdownNativeView: UIScrollView {
    private let contentStack = UIStackView()
    private var renderedMarkdown: String?

    init(markdown: String) {
        super.init(frame: .zero)
        alwaysBounceVertical = true
        keyboardDismissMode = .interactive
        contentStack.axis = .vertical
        contentStack.alignment = .fill
        contentStack.spacing = 12
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: contentLayoutGuide.leadingAnchor, constant: 16),
            contentStack.trailingAnchor.constraint(equalTo: contentLayoutGuide.trailingAnchor, constant: -16),
            contentStack.topAnchor.constraint(equalTo: contentLayoutGuide.topAnchor, constant: 16),
            contentStack.bottomAnchor.constraint(equalTo: contentLayoutGuide.bottomAnchor, constant: -16),
            contentStack.widthAnchor.constraint(equalTo: frameLayoutGuide.widthAnchor, constant: -32),
        ])
        update(markdown: markdown)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(markdown: String) {
        guard renderedMarkdown != markdown else { return }
        renderedMarkdown = markdown
        for view in contentStack.arrangedSubviews {
            contentStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for block in ChatArtifactMarkdownDocument(markdown: markdown).blocks {
            contentStack.addArrangedSubview(view(for: block))
        }
    }

    private func view(for block: ChatArtifactMarkdownBlock) -> UIView {
        switch block.kind {
        case .heading(let level):
            return textView(
                text: block.text,
                font: headingFont(level: level),
                color: .label
            )
        case .paragraph:
            return textView(
                text: block.text,
                font: .preferredFont(forTextStyle: .body),
                color: .label
            )
        case .bullet(let indent):
            return listRow(marker: "•", text: block.text, indent: indent)
        case .ordered(let marker, let indent):
            return listRow(marker: marker, text: block.text, indent: indent)
        case .quote:
            let rail = UIView()
            rail.backgroundColor = .separator
            rail.translatesAutoresizingMaskIntoConstraints = false
            rail.widthAnchor.constraint(equalToConstant: 3).isActive = true
            let row = UIStackView(arrangedSubviews: [
                rail,
                textView(
                    text: block.text,
                    font: .preferredFont(forTextStyle: .body),
                    color: .secondaryLabel
                ),
            ])
            row.axis = .horizontal
            row.alignment = .fill
            row.spacing = 10
            return row
        case .rule:
            let rule = UIView()
            rule.backgroundColor = .separator
            rule.heightAnchor.constraint(equalToConstant: 1).isActive = true
            return rule
        case .code(let language):
            return codeBlock(language: language, code: block.text)
        case .tableRow(let isHeader):
            return horizontallyScrollableText(
                block.text,
                font: .monospacedSystemFont(
                    ofSize: UIFont.preferredFont(forTextStyle: .body).pointSize,
                    weight: isHeader ? .semibold : .regular
                ),
                backgroundColor: .clear,
                contentInsets: .zero
            )
        }
    }

    private func listRow(marker: String, text: String, indent: Int) -> UIView {
        let markerLabel = UILabel()
        markerLabel.text = marker
        markerLabel.font = .preferredFont(forTextStyle: .body)
        markerLabel.textColor = .secondaryLabel
        markerLabel.textAlignment = .right
        markerLabel.translatesAutoresizingMaskIntoConstraints = false
        markerLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 20).isActive = true

        let row = UIStackView(arrangedSubviews: [
            markerLabel,
            textView(
                text: text,
                font: .preferredFont(forTextStyle: .body),
                color: .label
            ),
        ])
        row.axis = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 8

        let container = UIView()
        row.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(
                equalTo: container.leadingAnchor,
                constant: CGFloat(min(indent, 4)) * 16
            ),
            row.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            row.topAnchor.constraint(equalTo: container.topAnchor),
            row.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    private func codeBlock(language: String?, code: String) -> UIView {
        let header = UILabel()
        header.text = language.flatMap { $0.isEmpty ? nil : $0.uppercased() }
        header.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
        header.textColor = .secondaryLabel
        header.isHidden = header.text == nil

        let scroller = horizontallyScrollableText(
            code.isEmpty ? " " : code,
            font: .monospacedSystemFont(
                ofSize: UIFont.preferredFont(forTextStyle: .body).pointSize,
                weight: .regular
            ),
            backgroundColor: .clear,
            contentInsets: .zero
        )
        let stack = UIStackView(arrangedSubviews: [header, scroller])
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = UIView()
        container.backgroundColor = .secondarySystemBackground
        container.layer.cornerRadius = 8
        container.layer.cornerCurve = .continuous
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
        ])
        return container
    }

    private func textView(text: String, font: UIFont, color: UIColor) -> UITextView {
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        options.failurePolicy = .returnPartiallyParsedIfPossible
        let rendered = (try? AttributedString(markdown: text, options: options))
            ?? AttributedString(text)
        let attributed = NSMutableAttributedString(attributedString: NSAttributedString(rendered))
        let range = NSRange(location: 0, length: attributed.length)
        attributed.addAttribute(.foregroundColor, value: color, range: range)
        var missingFontRanges: [NSRange] = []
        attributed.enumerateAttribute(.font, in: range) { value, range, _ in
            if value == nil { missingFontRanges.append(range) }
        }
        for missingRange in missingFontRanges {
            attributed.addAttribute(.font, value: font, range: missingRange)
        }

        let view = UITextView()
        view.attributedText = attributed
        view.backgroundColor = .clear
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.linkTextAttributes = [.foregroundColor: UIColor.systemBlue]
        view.setContentCompressionResistancePriority(.required, for: .vertical)
        return view
    }

    private func horizontallyScrollableText(
        _ text: String,
        font: UIFont,
        backgroundColor: UIColor,
        contentInsets: NSDirectionalEdgeInsets
    ) -> UIView {
        ChatArtifactHorizontalTextView(
            text: text,
            font: font,
            backgroundColor: backgroundColor,
            contentInsets: contentInsets
        )
    }

    private func headingFont(level: Int) -> UIFont {
        switch level {
        case 1:
            return .systemFont(
                ofSize: UIFont.preferredFont(forTextStyle: .title1).pointSize,
                weight: .bold
            )
        case 2:
            return .systemFont(
                ofSize: UIFont.preferredFont(forTextStyle: .title2).pointSize,
                weight: .bold
            )
        case 3:
            return .systemFont(
                ofSize: UIFont.preferredFont(forTextStyle: .title3).pointSize,
                weight: .semibold
            )
        default:
            return .preferredFont(forTextStyle: .headline)
        }
    }
}

@MainActor
private final class ChatArtifactHorizontalTextView: UITextView {
    private let measuredHeight: CGFloat

    init(
        text: String,
        font: UIFont,
        backgroundColor: UIColor,
        contentInsets: NSDirectionalEdgeInsets
    ) {
        let lineCount = max(text.split(separator: "\n", omittingEmptySubsequences: false).count, 1)
        measuredHeight = ceil(font.lineHeight * CGFloat(lineCount))
            + contentInsets.top
            + contentInsets.bottom
        super.init(frame: .zero, textContainer: nil)
        self.text = text
        self.font = font
        self.textColor = .label
        self.backgroundColor = backgroundColor
        isEditable = false
        isSelectable = true
        isScrollEnabled = true
        alwaysBounceHorizontal = false
        alwaysBounceVertical = false
        showsHorizontalScrollIndicator = true
        showsVerticalScrollIndicator = false
        isDirectionalLockEnabled = true
        textContainerInset = UIEdgeInsets(
            top: contentInsets.top,
            left: contentInsets.leading,
            bottom: contentInsets.bottom,
            right: contentInsets.trailing
        )
        textContainer.lineFragmentPadding = 0
        textContainer.widthTracksTextView = false
        textContainer.heightTracksTextView = false
        textContainer.size = CGSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: measuredHeight
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: measuredHeight)
    }
}
#endif
