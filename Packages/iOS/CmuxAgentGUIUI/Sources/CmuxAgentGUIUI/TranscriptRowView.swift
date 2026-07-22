#if os(iOS)
import CmuxAgentGUIProjection
import CmuxAgentReplica
import UIKit

@MainActor final class TranscriptRowView: UIView {
    private static let buttonActionIdentifier = UIAction.Identifier("cmux.transcript.row-button")
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
        alpha = if case .streaming = row.rowKind { 0.82 } else { 1 }
        resizeBackgroundViews(to: layout.backgroundElements.count)
        resizeTextViews(to: layout.textElements.count)
        resizeGlyphViews(for: layout.glyphElements)
        resizeButtons(to: layout.buttonElements.count)
        for (view, element) in zip(backgroundViews, layout.backgroundElements) {
            updateBackground(view, element: element, theme: theme)
        }
        for (view, element) in zip(textViews, layout.textElements) {
            updateTextView(view, element: element, theme: theme)
        }
        for (view, element) in zip(glyphViews, layout.glyphElements) {
            updateGlyphView(view, element: element, theme: theme)
        }
        let isAnswering = if case .pendingAsk(let ask) = row.rowKind {
            answeringAskID == ask.id
        } else {
            false
        }
        for (button, element) in zip(buttons, layout.buttonElements) {
            updateButton(button, element: element, answering: isAnswering)
        }
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
            view.contentInset = .zero
            view.contentOffset = .zero
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

    private func resizeBackgroundViews(to count: Int) {
        trim(&backgroundViews, to: count)
        while backgroundViews.count < count {
            let view = UIView()
            view.isUserInteractionEnabled = false
            backgroundViews.append(view)
        }
    }

    private func resizeTextViews(to count: Int) {
        trim(&textViews, to: count)
        while textViews.count < count {
            let textView = UITextView(frame: .zero)
            TranscriptTextMeasurer().configure(textView)
            textViews.append(textView)
        }
    }

    private func resizeGlyphViews(for elements: [TranscriptRowGlyphElement]) {
        for index in elements.indices where glyphViews.indices.contains(index) {
            let hasMatchingKind = elements[index].isActivityIndicator
                ? glyphViews[index] is UIActivityIndicatorView
                : glyphViews[index] is UIImageView
            if !hasMatchingKind {
                glyphViews[index].removeFromSuperview()
                glyphViews[index] = makeGlyphView(isActivityIndicator: elements[index].isActivityIndicator)
            }
        }
        trim(&glyphViews, to: elements.count)
        while glyphViews.count < elements.count {
            glyphViews.append(makeGlyphView(isActivityIndicator: elements[glyphViews.count].isActivityIndicator))
        }
    }

    private func resizeButtons(to count: Int) {
        trim(&buttons, to: count)
        while buttons.count < count {
            buttons.append(UIButton(type: .system))
        }
    }

    private func trim<View: UIView>(_ views: inout [View], to count: Int) {
        guard views.count > count else { return }
        for view in views[count...] {
            view.removeFromSuperview()
        }
        views.removeLast(views.count - count)
    }

    private func updateBackground(
        _ view: UIView,
        element: TranscriptRowBackgroundElement,
        theme: AgentGUITheme
    ) {
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
    }

    private func updateTextView(
        _ textView: UITextView,
        element: TranscriptRowTextElement,
        theme: AgentGUITheme
    ) {
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
        textView.contentInset = .zero
        textView.contentOffset = .zero
        textView.textAlignment = element.alignment
        textView.textContainer.maximumNumberOfLines = element.maximumNumberOfLines
        if element.maximumNumberOfLines == 1 {
            textView.textContainer.lineBreakMode = .byTruncatingTail
        } else {
            textView.textContainer.lineBreakMode = .byWordWrapping
        }
        textView.linkTextAttributes = [
            .foregroundColor: UIColor(theme.accent),
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]
    }

    private func makeGlyphView(isActivityIndicator: Bool) -> UIView {
        if isActivityIndicator {
            return UIActivityIndicatorView(style: .medium)
        }
        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFit
        imageView.isAccessibilityElement = false
        return imageView
    }

    private func updateGlyphView(
        _ view: UIView,
        element: TranscriptRowGlyphElement,
        theme: AgentGUITheme
    ) {
        let tintColor = element.role == .accent
            ? UIColor(theme.accent)
            : UIColor(theme.faintForeground)
        if let indicator = view as? UIActivityIndicatorView {
            indicator.color = tintColor
            indicator.startAnimating()
            return
        }
        guard let imageView = view as? UIImageView else { return }
        imageView.tintColor = tintColor
        imageView.image = UIImage(
            systemName: element.systemName,
            withConfiguration: UIImage.SymbolConfiguration(
                pointSize: element.pointSize,
                weight: element.weight >= UIFont.Weight.semibold.rawValue ? .semibold : .regular
            )
        )
    }

    private func updateButton(
        _ button: UIButton,
        element: TranscriptRowButtonElement,
        answering: Bool
    ) {
        switch element.kind {
        case .askOption:
            var configuration = UIButton.Configuration.bordered()
            var attributedTitle = AttributedString(element.title ?? "")
            attributedTitle.font = UIFont.preferredFont(
                forTextStyle: .body,
                compatibleWith: traitCollection
            )
            configuration.attributedTitle = attributedTitle
            configuration.contentInsets = NSDirectionalEdgeInsets(
                top: TranscriptRowButtonElement.optionVerticalContentInset,
                leading: TranscriptRowButtonElement.optionHorizontalContentInset,
                bottom: TranscriptRowButtonElement.optionVerticalContentInset,
                trailing: TranscriptRowButtonElement.optionHorizontalContentInset
            )
            configuration.titleAlignment = .leading
            configuration.titleLineBreakMode = .byWordWrapping
            configuration.showsActivityIndicator = answering
            button.configuration = configuration
            button.titleLabel?.numberOfLines = 0
        case .showTerminal:
            var configuration = UIButton.Configuration.bordered()
            configuration.title = element.title
            button.configuration = configuration
            button.titleLabel?.numberOfLines = 1
        case .showActivity:
            var configuration = UIButton.Configuration.plain()
            configuration.contentInsets = .zero
            button.configuration = configuration
            button.titleLabel?.numberOfLines = 1
        }
        button.isEnabled = element.isEnabled
        button.accessibilityIdentifier = element.accessibilityIdentifier
        button.accessibilityLabel = element.accessibilityLabel
        button.accessibilityHint = element.accessibilityHint
        button.removeAction(identifiedBy: Self.buttonActionIdentifier, for: .touchUpInside)
        button.addAction(UIAction(identifier: Self.buttonActionIdentifier) { [weak self] _ in
            self?.perform(element.kind)
        }, for: .touchUpInside)
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
