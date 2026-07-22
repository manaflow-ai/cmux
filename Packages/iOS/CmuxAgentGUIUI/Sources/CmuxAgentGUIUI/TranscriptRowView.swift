#if os(iOS)
import CmuxAgentGUIProjection
import CmuxAgentReplica
import UIKit

@MainActor final class TranscriptRowView: UIView {
    private var layoutResult: TranscriptRowLayoutResult?
    private var backgroundViews: [UIView] = []
    private var textViews: [UITextView] = []
    private var glyphViews: [UIView] = []
    private var buttons: [UIButton] = []
    private var row: TranscriptRow?
    private var onShowActivity: (TranscriptActivityDetails) -> Void = { _ in }
    private var onAnswer: (PendingAsk, Int) -> Void = { _, _ in }
    private var onShowTerminal: () -> Void = {}

    var contentBoundsIncludingSubviews: CGRect {
        subviews.reduce(CGRect.null) { bounds, view in
            guard !view.isHidden, view.alpha > 0.01 else { return bounds }
            return bounds.union(view.frame)
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        clipsToBounds = true
    }

    required init?(coder: NSCoder) {
        nil
    }

    func configure(
        row: TranscriptRow,
        layout: TranscriptRowLayoutResult,
        theme: AgentGUITheme,
        answeringAskID: String?,
        onShowActivity: @escaping (TranscriptActivityDetails) -> Void,
        onAnswer: @escaping (PendingAsk, Int) -> Void,
        onShowTerminal: @escaping () -> Void
    ) {
        self.row = row
        layoutResult = layout
        self.onShowActivity = onShowActivity
        self.onAnswer = onAnswer
        self.onShowTerminal = onShowTerminal
        removeRenderedSubviews()
        backgroundViews = layout.backgroundElements.map { makeBackground($0, theme: theme) }
        textViews = layout.textElements.map { makeTextView($0, theme: theme) }
        glyphViews = layout.glyphElements.map { makeGlyphView($0, theme: theme) }
        let isAnswering = if case .pendingAsk(let ask) = row.rowKind {
            answeringAskID == ask.id
        } else {
            false
        }
        buttons = layout.buttonElements.map { makeButton($0, answering: isAnswering) }
        backgroundViews.forEach(addSubview)
        textViews.forEach(addSubview)
        glyphViews.forEach(addSubview)
        buttons.forEach(addSubview)
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let layoutResult else { return }
        for (view, element) in zip(backgroundViews, layoutResult.backgroundElements) {
            view.frame = element.frame
        }
        for (view, element) in zip(textViews, layoutResult.textElements) {
            view.frame = element.frame
            view.textContainer.size = CGSize(
                width: element.frame.width,
                height: .greatestFiniteMagnitude
            )
        }
        for (view, element) in zip(glyphViews, layoutResult.glyphElements) {
            view.frame = element.frame
        }
        for (view, element) in zip(buttons, layoutResult.buttonElements) {
            view.frame = element.frame
        }
    }

    private func removeRenderedSubviews() {
        subviews.forEach { $0.removeFromSuperview() }
        backgroundViews.removeAll(keepingCapacity: true)
        textViews.removeAll(keepingCapacity: true)
        glyphViews.removeAll(keepingCapacity: true)
        buttons.removeAll(keepingCapacity: true)
    }

    private func makeBackground(
        _ element: TranscriptRowBackgroundElement,
        theme: AgentGUITheme
    ) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.layer.cornerRadius = element.cornerRadius
        view.layer.cornerCurve = .continuous
        view.clipsToBounds = true
        view.backgroundColor = switch element.kind {
        case .userBubble: UIColor(theme.inputBackground)
        case .pendingBubble: UIColor(theme.raisedBackground)
        case .askCard: UIColor(theme.hoverBackground).withAlphaComponent(0.55)
        case .codeBlock: UIColor(theme.hoverBackground).withAlphaComponent(0.45)
        case .inlineCode: UIColor(theme.hoverBackground).withAlphaComponent(0.55)
        }
        return view
    }

    private func makeTextView(
        _ element: TranscriptRowTextElement,
        theme: AgentGUITheme
    ) -> UITextView {
        let textView = UITextView(frame: .zero)
        TranscriptTextMeasurer().configure(textView)
        textView.textContainer.size = CGSize(
            width: element.frame.width,
            height: .greatestFiniteMagnitude
        )
        let rendered = NSMutableAttributedString(attributedString: element.attributedText.value)
        let foreground = switch element.role {
        case .foreground: UIColor(theme.foreground)
        case .dim: UIColor(theme.dimForeground)
        case .faint: UIColor(theme.faintForeground)
        case .error: UIColor.systemRed
        }
        let fullRange = NSRange(location: 0, length: rendered.length)
        rendered.addAttribute(.foregroundColor, value: foreground, range: fullRange)
        rendered.enumerateAttribute(.transcriptInlineCode, in: fullRange) { value, range, _ in
            guard value != nil else { return }
            rendered.addAttribute(
                .backgroundColor,
                value: UIColor(theme.hoverBackground).withAlphaComponent(0.65),
                range: range
            )
        }
        textView.attributedText = rendered
        textView.textAlignment = element.alignment
        textView.textContainer.maximumNumberOfLines = element.maximumNumberOfLines
        if element.maximumNumberOfLines == 1 {
            textView.textContainer.lineBreakMode = .byTruncatingTail
        }
        textView.linkTextAttributes = [
            .foregroundColor: UIColor(theme.accent),
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]
        return textView
    }

    private func makeGlyphView(
        _ element: TranscriptRowGlyphElement,
        theme: AgentGUITheme
    ) -> UIView {
        let tintColor = element.role == .accent
            ? UIColor(theme.accent)
            : UIColor(theme.faintForeground)
        if element.isActivityIndicator {
            let indicator = UIActivityIndicatorView(style: .medium)
            indicator.color = tintColor
            indicator.startAnimating()
            return indicator
        }
        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFit
        imageView.tintColor = tintColor
        imageView.image = UIImage(
            systemName: element.systemName,
            withConfiguration: UIImage.SymbolConfiguration(
                pointSize: element.pointSize,
                weight: element.weight >= UIFont.Weight.semibold.rawValue ? .semibold : .regular
            )
        )
        imageView.isAccessibilityElement = false
        return imageView
    }

    private func makeButton(
        _ element: TranscriptRowButtonElement,
        answering: Bool
    ) -> UIButton {
        let button = UIButton(type: .system)
        switch element.kind {
        case .askOption:
            var configuration = UIButton.Configuration.bordered()
            configuration.title = element.title
            configuration.titleAlignment = .leading
            configuration.showsActivityIndicator = answering
            button.configuration = configuration
        case .showTerminal:
            var configuration = UIButton.Configuration.bordered()
            configuration.title = element.title
            button.configuration = configuration
        case .showActivity:
            var configuration = UIButton.Configuration.plain()
            configuration.contentInsets = .zero
            button.configuration = configuration
        }
        button.isEnabled = element.isEnabled
        button.accessibilityIdentifier = element.accessibilityIdentifier
        button.accessibilityLabel = element.accessibilityLabel
        button.accessibilityHint = element.accessibilityHint
        button.addAction(UIAction { [weak self] _ in
            self?.perform(element.kind)
        }, for: .touchUpInside)
        return button
    }

    private func perform(_ kind: TranscriptRowButtonKind) {
        guard let row else { return }
        switch kind {
        case .askOption(let index):
            guard case .pendingAsk(let ask) = row.rowKind else { return }
            onAnswer(ask, index)
        case .showTerminal:
            onShowTerminal()
        case .showActivity:
            guard case .activitySummary(let summary) = row.rowKind,
                  let turnID = row.turnID
            else {
                return
            }
            onShowActivity(TranscriptActivityDetails(turnID: turnID, summary: summary))
        }
    }
}
#endif
