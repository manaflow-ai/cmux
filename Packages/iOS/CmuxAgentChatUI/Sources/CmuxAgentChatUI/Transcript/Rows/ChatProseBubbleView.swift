import CmuxAgentChat

#if canImport(UIKit)
import UIKit

/// Native prose bubble backed by TextKit and UIKit code-block controls.
@MainActor
public final class ChatProseBubbleView: UIView, UIContextMenuInteractionDelegate {
    private static let codeBlockLineCap = 8
    private let prose: ChatProse
    private let onCopied: @MainActor () -> Void

    public init(
        prose: ChatProse,
        message: ChatMessage,
        groupPosition: ChatGroupPosition,
        showsTimestamp: Bool,
        contentCache: ChatContentCache? = nil,
        renderer: ChatMarkdownRenderer? = nil,
        onShowCodeDetail: @escaping @MainActor (String, Int) -> Void = { _, _ in },
        onCopied: @escaping @MainActor () -> Void = {}
    ) {
        self.prose = prose
        self.onCopied = onCopied
        super.init(frame: .zero)

        let isUser = message.role == .user
        let segments = contentCache?.proseSegments(messageID: message.id, text: prose.text)
            ?? ChatProseSegmenter().segments(from: prose.text)
        let hasCode = !isUser && segments.contains {
            if case .code = $0.kind { return true }
            return false
        }

        let bubbleContent = UIStackView()
        bubbleContent.axis = .vertical
        bubbleContent.alignment = .fill
        bubbleContent.spacing = isUser ? 0 : 8
        if isUser {
            bubbleContent.addArrangedSubview(textView(
                attributedText: NSAttributedString(string: prose.text),
                font: .preferredFont(forTextStyle: .body),
                color: .white
            ))
        } else {
            for segment in segments {
                switch segment.kind {
                case .text:
                    for block in textBlocks(segment, messageID: message.id, cache: contentCache) {
                        bubbleContent.addArrangedSubview(blockView(
                            block,
                            segmentIndex: segment.index,
                            messageID: message.id,
                            renderer: renderer
                        ))
                    }
                case .code(let language):
                    bubbleContent.addArrangedSubview(ChatNativeCodeBlockView(
                        language: language,
                        code: segment.content,
                        messageID: message.id,
                        segmentIndex: segment.index,
                        lineCap: Self.codeBlockLineCap,
                        onShowDetail: onShowCodeDetail,
                        onCopy: { [weak self] in self?.copyProse() }
                    ))
                }
            }
        }

        let bubble = ChatBubbleBackgroundView(
            color: isUser ? .systemBlue : .secondarySystemBackground,
            radii: Self.radii(position: groupPosition, trailing: isUser)
        )
        bubbleContent.translatesAutoresizingMaskIntoConstraints = false
        bubble.addSubview(bubbleContent)
        NSLayoutConstraint.activate([
            bubbleContent.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 12),
            bubbleContent.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -12),
            bubbleContent.topAnchor.constraint(equalTo: bubble.topAnchor, constant: 8),
            bubbleContent.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -8),
        ])

        let column = UIStackView(arrangedSubviews: [bubble])
        column.axis = .vertical
        column.alignment = isUser ? .trailing : .leading
        column.spacing = 3
        if showsTimestamp {
            let timestamp = UILabel()
            timestamp.text = message.timestamp.formatted(.dateTime.hour().minute())
            timestamp.font = .preferredFont(forTextStyle: .caption2)
            timestamp.textColor = .tertiaryLabel
            column.addArrangedSubview(timestamp)
        }
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
            bubble.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.78),
        ])
        if isUser {
            NSLayoutConstraint.activate([
                column.trailingAnchor.constraint(equalTo: trailingAnchor),
                column.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 64),
            ])
        } else {
            NSLayoutConstraint.activate([
                column.leadingAnchor.constraint(equalTo: leadingAnchor),
                column.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -64),
            ])
        }

        bubble.addInteraction(UIContextMenuInteraction(delegate: self))
        accessibilityCustomActions = [
            copyAccessibilityAction(),
        ]
        isAccessibilityElement = !hasCode
        accessibilityLabel = prose.text
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        UIContextMenuConfiguration(actionProvider: { [weak self] _ in
            UIMenu(children: [
                UIAction(
                    title: String(
                        localized: "chat.bubble.copy",
                        defaultValue: "Copy",
                        bundle: .module
                    ),
                    image: UIImage(systemName: "doc.on.doc")
                ) { _ in
                    self?.copyProse()
                },
            ])
        })
    }

    @objc private func copyForAccessibility() -> Bool {
        copyProse()
        return true
    }

    private func copyProse() {
        UIPasteboard.general.string = prose.text
        onCopied()
    }

    private func copyAccessibilityAction() -> UIAccessibilityCustomAction {
        UIAccessibilityCustomAction(
            name: String(localized: "chat.bubble.copy", defaultValue: "Copy", bundle: .module),
            target: self,
            selector: #selector(copyForAccessibility)
        )
    }

    private func textBlocks(
        _ segment: ChatProseSegment,
        messageID: String,
        cache: ChatContentCache?
    ) -> [ChatTextBlock] {
        cache?.textBlocks(messageID: "\(messageID)#\(segment.index)", text: segment.content)
            ?? ChatTextBlockParser().blocks(from: segment.content)
    }

    private func blockView(
        _ block: ChatTextBlock,
        segmentIndex: Int,
        messageID: String,
        renderer: ChatMarkdownRenderer?
    ) -> UIView {
        if case .rule = block.kind {
            let rule = UIView()
            rule.backgroundColor = .separator
            rule.heightAnchor.constraint(equalToConstant: 1).isActive = true
            return rule
        }

        let rendered = renderer?.render(
            messageID: "\(messageID)#\(segmentIndex).\(block.index)",
            markdown: block.text
        ) ?? AttributedString(block.text)
        let attributed = NSAttributedString(rendered)
        switch block.kind {
        case .heading(let level):
            let font: UIFont
            switch level {
            case 1:
                font = .preferredFont(forTextStyle: .title3).weighted(.bold)
            case 2:
                font = .preferredFont(forTextStyle: .headline)
            default:
                font = .preferredFont(forTextStyle: .subheadline).weighted(.semibold)
            }
            return textView(attributedText: attributed, font: font, color: .label)
        case .paragraph:
            return textView(
                attributedText: attributed,
                font: .preferredFont(forTextStyle: .body),
                color: .label
            )
        case .bullet(let indent):
            return listRow(marker: "•", attributed: attributed, indent: indent)
        case .ordered(let marker, let indent):
            return listRow(marker: marker, attributed: attributed, indent: indent)
        case .quote:
            let rail = UIView()
            rail.backgroundColor = .separator
            rail.translatesAutoresizingMaskIntoConstraints = false
            rail.widthAnchor.constraint(equalToConstant: 3).isActive = true
            let row = UIStackView(arrangedSubviews: [rail, textView(
                attributedText: attributed,
                font: .preferredFont(forTextStyle: .body),
                color: .secondaryLabel
            )])
            row.axis = .horizontal
            row.alignment = .fill
            row.spacing = 8
            return row
        case .rule:
            preconditionFailure("Rules return before text rendering")
        }
    }

    private func listRow(marker: String, attributed: NSAttributedString, indent: Int) -> UIView {
        let markerLabel = UILabel()
        markerLabel.text = marker
        markerLabel.font = .preferredFont(forTextStyle: .body)
        markerLabel.textColor = .secondaryLabel
        markerLabel.textAlignment = .right
        markerLabel.translatesAutoresizingMaskIntoConstraints = false
        markerLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 16).isActive = true
        let row = UIStackView(arrangedSubviews: [markerLabel, textView(
            attributedText: attributed,
            font: .preferredFont(forTextStyle: .body),
            color: .label
        )])
        row.axis = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 6
        if indent > 0 {
            let container = UIView()
            row.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(row)
            NSLayoutConstraint.activate([
                row.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: CGFloat(min(indent, 4)) * 14),
                row.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                row.topAnchor.constraint(equalTo: container.topAnchor),
                row.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
            return container
        }
        return row
    }

    private func textView(
        attributedText: NSAttributedString,
        font: UIFont,
        color: UIColor
    ) -> UITextView {
        let text = NSMutableAttributedString(attributedString: attributedText)
        let fullRange = NSRange(location: 0, length: text.length)
        text.addAttributes([.foregroundColor: color], range: fullRange)
        var missingFontRanges: [NSRange] = []
        text.enumerateAttribute(.font, in: fullRange) { value, range, _ in
            if value == nil {
                missingFontRanges.append(range)
            }
        }
        for range in missingFontRanges {
            text.addAttribute(.font, value: font, range: range)
        }
        let view = UITextView()
        view.attributedText = text
        view.backgroundColor = .clear
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.adjustsFontForContentSizeCategory = true
        view.linkTextAttributes = [.foregroundColor: UIColor.systemBlue]
        view.accessibilityCustomActions = [copyAccessibilityAction()]
        view.setContentCompressionResistancePriority(.required, for: .vertical)
        return view
    }

    private static func radii(position: ChatGroupPosition, trailing: Bool) -> ChatBubbleRadii {
        let full: CGFloat = 18
        let tight: CGFloat = 6
        let tightTop = position == .middle || position == .last
        let tightBottom = position == .first || position == .middle
        if trailing {
            return ChatBubbleRadii(
                topLeft: full,
                topRight: tightTop ? tight : full,
                bottomRight: tightBottom ? tight : full,
                bottomLeft: full
            )
        }
        return ChatBubbleRadii(
            topLeft: tightTop ? tight : full,
            topRight: full,
            bottomRight: full,
            bottomLeft: tightBottom ? tight : full
        )
    }
}

@MainActor
private final class ChatNativeCodeBlockView: UIControl {
    private let messageID: String
    private let segmentIndex: Int
    private let onShowDetail: @MainActor (String, Int) -> Void
    private let onCopy: @MainActor () -> Void

    init(
        language: String?,
        code: String,
        messageID: String,
        segmentIndex: Int,
        lineCap: Int,
        onShowDetail: @escaping @MainActor (String, Int) -> Void,
        onCopy: @escaping @MainActor () -> Void
    ) {
        self.messageID = messageID
        self.segmentIndex = segmentIndex
        self.onShowDetail = onShowDetail
        self.onCopy = onCopy
        super.init(frame: .zero)
        backgroundColor = UIColor(white: 0.055, alpha: 1)
        layer.cornerRadius = 8
        accessibilityIdentifier = "ChatCodeBlockDetail-\(messageID)-\(segmentIndex)"
        let codeLabel = String(
            localized: "chat.code_block.accessibility",
            defaultValue: "Code block",
            bundle: .module
        )
        accessibilityLabel = language.flatMap { $0.isEmpty ? nil : "\($0) \(codeLabel)" } ?? codeLabel
        accessibilityHint = String(
            localized: "chat.detail.show.hint",
            defaultValue: "Opens a sheet with the full block content",
            bundle: .module
        )
        accessibilityCustomActions = [
            UIAccessibilityCustomAction(
                name: String(localized: "chat.bubble.copy", defaultValue: "Copy", bundle: .module),
                target: self,
                selector: #selector(copyMessage)
            ),
        ]
        addTarget(self, action: #selector(showDetail), for: .primaryActionTriggered)

        let header = UILabel()
        header.text = language.flatMap { $0.isEmpty ? nil : $0.uppercased() }
            ?? String(localized: "chat.detail.code.section", defaultValue: "Code", bundle: .module)
        header.font = .monospacedSystemFont(ofSize: 10, weight: .semibold)
        header.textColor = UIColor(white: 0.88, alpha: 0.6)

        let lines = code.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let visible = lines.count > lineCap ? Array(lines.prefix(lineCap)) : lines
        let codeText = UILabel()
        codeText.text = visible.joined(separator: "\n").isEmpty ? " " : visible.joined(separator: "\n")
        codeText.font = .monospacedSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .caption1).pointSize, weight: .regular)
        codeText.textColor = UIColor(white: 0.88, alpha: 1)
        codeText.numberOfLines = 0
        codeText.lineBreakMode = .byClipping
        codeText.translatesAutoresizingMaskIntoConstraints = false

        let codeScroller = UIScrollView()
        codeScroller.showsHorizontalScrollIndicator = true
        codeScroller.isDirectionalLockEnabled = true
        codeScroller.isAccessibilityElement = false
        codeText.isAccessibilityElement = false
        codeScroller.addSubview(codeText)
        NSLayoutConstraint.activate([
            codeText.leadingAnchor.constraint(equalTo: codeScroller.contentLayoutGuide.leadingAnchor),
            codeText.trailingAnchor.constraint(equalTo: codeScroller.contentLayoutGuide.trailingAnchor),
            codeText.topAnchor.constraint(equalTo: codeScroller.contentLayoutGuide.topAnchor),
            codeText.bottomAnchor.constraint(equalTo: codeScroller.contentLayoutGuide.bottomAnchor),
            codeText.widthAnchor.constraint(greaterThanOrEqualTo: codeScroller.frameLayoutGuide.widthAnchor),
            codeScroller.heightAnchor.constraint(equalTo: codeText.heightAnchor),
        ])

        let stack = UIStackView(arrangedSubviews: [header, codeScroller])
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 6
        if lines.count > lineCap {
            let more = UILabel()
            more.text = String(
                localized: "chat.terminal.more_lines",
                defaultValue: "⋯ \(lines.count - lineCap) more lines",
                bundle: .module
            )
            more.font = .monospacedSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .caption1).pointSize, weight: .regular)
            more.textColor = .secondaryLabel
            stack.addArrangedSubview(more)
        }
        let tap = UITapGestureRecognizer(target: self, action: #selector(showDetail))
        tap.cancelsTouchesInView = false
        stack.addGestureRecognizer(tap)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func showDetail() {
        onShowDetail(messageID, segmentIndex)
    }

    @objc private func copyMessage() -> Bool {
        onCopy()
        return true
    }
}

private struct ChatBubbleRadii {
    let topLeft: CGFloat
    let topRight: CGFloat
    let bottomRight: CGFloat
    let bottomLeft: CGFloat
}

@MainActor
private final class ChatBubbleBackgroundView: UIView {
    private let fillLayer = CAShapeLayer()
    private let fillColor: UIColor
    private let radii: ChatBubbleRadii

    init(color: UIColor, radii: ChatBubbleRadii) {
        self.fillColor = color
        self.radii = radii
        super.init(frame: .zero)
        updateFillColor()
        layer.insertSublayer(fillLayer, at: 0)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) {
            (view: ChatBubbleBackgroundView, _: UITraitCollection) in
            view.updateFillColor()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        fillLayer.frame = bounds
        fillLayer.path = Self.path(in: bounds, radii: radii).cgPath
    }

    private func updateFillColor() {
        fillLayer.fillColor = fillColor.resolvedColor(with: traitCollection).cgColor
    }

    private static func path(in rect: CGRect, radii: ChatBubbleRadii) -> UIBezierPath {
        let path = UIBezierPath()
        path.move(to: CGPoint(x: rect.minX + radii.topLeft, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - radii.topRight, y: rect.minY))
        path.addArc(
            withCenter: CGPoint(x: rect.maxX - radii.topRight, y: rect.minY + radii.topRight),
            radius: radii.topRight,
            startAngle: -.pi / 2,
            endAngle: 0,
            clockwise: true
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radii.bottomRight))
        path.addArc(
            withCenter: CGPoint(x: rect.maxX - radii.bottomRight, y: rect.maxY - radii.bottomRight),
            radius: radii.bottomRight,
            startAngle: 0,
            endAngle: .pi / 2,
            clockwise: true
        )
        path.addLine(to: CGPoint(x: rect.minX + radii.bottomLeft, y: rect.maxY))
        path.addArc(
            withCenter: CGPoint(x: rect.minX + radii.bottomLeft, y: rect.maxY - radii.bottomLeft),
            radius: radii.bottomLeft,
            startAngle: .pi / 2,
            endAngle: .pi,
            clockwise: true
        )
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radii.topLeft))
        path.addArc(
            withCenter: CGPoint(x: rect.minX + radii.topLeft, y: rect.minY + radii.topLeft),
            radius: radii.topLeft,
            startAngle: .pi,
            endAngle: .pi * 1.5,
            clockwise: true
        )
        path.close()
        return path
    }
}

private extension UIFont {
    func weighted(_ weight: UIFont.Weight) -> UIFont {
        UIFont.systemFont(ofSize: pointSize, weight: weight)
    }
}
#endif
