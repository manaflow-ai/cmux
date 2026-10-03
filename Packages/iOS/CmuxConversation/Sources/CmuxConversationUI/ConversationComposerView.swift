#if canImport(UIKit)
import UIKit

/// A picked image waiting in the composer.
struct ComposerAttachment {
    let id = UUID()
    var image: UIImage
    var data: Data
    var mimeType: String
}

@MainActor
protocol ConversationComposerViewDelegate: AnyObject {
    func composerDidChangeText(_ composer: ConversationComposerView)
    func composerDidChangeHeight(_ composer: ConversationComposerView)
    func composerDidTapSend(_ composer: ConversationComposerView)
    func composerDidTapPlus(_ composer: ConversationComposerView)
}

/// Messages composer: a glass "+" circle and a glass capsule field that grows
/// one 24 pt line at a time (no animation), up to `maximumFieldHeight`, then
/// scrolls. The send button lives inside the field and appears with content.
final class ConversationComposerView: UIView, UITextViewDelegate {
    weak var delegate: (any ConversationComposerViewDelegate)?

    let plusButton = UIButton(type: .system)
    private let plusGlass = makeGlassView(cornerRadius: ConversationTheme.plusButtonSize / 2, interactive: true)
    let fieldGlass = makeGlassView(cornerRadius: ConversationTheme.composerMinHeight / 2, interactive: false)
    let textView = ComposerTextView()
    private let placeholder = UILabel()
    let sendButton = UIButton(type: .custom)
    private let micButton = UIButton(type: .system)
    private let attachmentStrip = UIScrollView()
    private let attachmentSeparator = UIView()
    private var attachmentViews: [UIView] = []
    private(set) var attachments: [ComposerAttachment] = []

    /// Set by the controller: the field may grow until it reaches the header.
    var maximumFieldHeight: CGFloat = 600 { didSet { if oldValue != maximumFieldHeight { updateHeight() } } }
    var placeholderText = String(localized: "conversation.composer.placeholder", defaultValue: "iMessage", bundle: .module) {
        didSet { updatePlaceholder() }
    }
    var replyPlaceholderText = String(localized: "conversation.composer.reply", defaultValue: "Reply", bundle: .module)
    var isReplyMode = false { didSet { updatePlaceholder() } }
    /// Editing one of my messages: the send button becomes a checkmark.
    var isEditMode = false {
        didSet {
            let symbol = isEditMode ? "checkmark" : "arrow.up"
            sendButton.setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .bold)), for: .normal)
            sendButton.accessibilityLabel = isEditMode
                ? String(localized: "conversation.composer.saveEdit", defaultValue: "Save Edit", bundle: .module)
                : String(localized: "conversation.composer.send", defaultValue: "Send", bundle: .module)
        }
    }

    private(set) var fieldHeight: CGFloat = ConversationTheme.composerMinHeight
    private let attachmentHeight: CGFloat = 120
    private let verticalPadding: CGFloat = 9
    private let fieldTextInset: CGFloat = 14.5
    private let sendSize = CGSize(width: 37, height: 28)

    var text: String {
        get { textView.text ?? "" }
        set {
            textView.text = newValue
            textDidChange()
        }
    }

    var hasContent: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
    }

    /// Total height of the composer row (field + vertical margins).
    var preferredHeight: CGFloat { fieldHeight + 2 * 4 }

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(plusGlass)
        plusGlass.contentView.addSubview(plusButton)
        plusButton.setImage(UIImage(systemName: "plus", withConfiguration: UIImage.SymbolConfiguration(pointSize: 19, weight: .medium)), for: .normal)
        plusButton.tintColor = .label
        plusButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.delegate?.composerDidTapPlus(self)
        }, for: .touchUpInside)
        plusButton.accessibilityLabel = String(localized: "conversation.composer.plus", defaultValue: "Apps", bundle: .module)
        plusButton.accessibilityIdentifier = "conversation.composer.plus"

        addSubview(fieldGlass)
        fieldGlass.layer.borderWidth = 0.5
        fieldGlass.layer.borderColor = UIColor.separator.cgColor
        fieldGlass.contentView.addSubview(attachmentStrip)
        fieldGlass.contentView.addSubview(attachmentSeparator)
        attachmentSeparator.backgroundColor = .separator
        attachmentStrip.showsHorizontalScrollIndicator = false
        attachmentStrip.isHidden = true
        attachmentSeparator.isHidden = true

        textView.font = ConversationTheme.bodyFont
        textView.typingAttributes = [
            .font: ConversationTheme.bodyFont,
            .foregroundColor: UIColor.label,
            .paragraphStyle: ConversationTheme.bodyParagraph,
        ]
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: verticalPadding, left: 0, bottom: verticalPadding, right: 0)
        textView.textContainer.lineFragmentPadding = 0
        textView.isScrollEnabled = false
        textView.delegate = self
        textView.returnKeyType = .default
        textView.accessibilityIdentifier = "conversation.composer.text"
        fieldGlass.contentView.addSubview(textView)

        placeholder.font = ConversationTheme.bodyFont
        placeholder.textColor = .placeholderText
        placeholder.isUserInteractionEnabled = false
        fieldGlass.contentView.addSubview(placeholder)
        updatePlaceholder()

        sendButton.backgroundColor = .systemBlue
        sendButton.setImage(UIImage(systemName: "arrow.up", withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .bold)), for: .normal)
        sendButton.tintColor = .white
        sendButton.layer.cornerRadius = sendSize.height / 2
        sendButton.layer.cornerCurve = .continuous
        sendButton.accessibilityLabel = String(localized: "conversation.composer.send", defaultValue: "Send", bundle: .module)
        sendButton.accessibilityIdentifier = "conversation.composer.send"
        sendButton.addAction(UIAction { [weak self] _ in
            guard let self, self.hasContent else { return }
            self.delegate?.composerDidTapSend(self)
        }, for: .touchUpInside)
        sendButton.alpha = 0
        sendButton.transform = CGAffineTransform(scaleX: 0.4, y: 0.4)
        fieldGlass.contentView.addSubview(sendButton)

        micButton.setImage(UIImage(systemName: "mic", withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .regular)), for: .normal)
        micButton.tintColor = .secondaryLabel
        micButton.isUserInteractionEnabled = false
        micButton.isAccessibilityElement = false
        fieldGlass.contentView.addSubview(micButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let t = ConversationTheme.self
        let plusSize = t.plusButtonSize
        plusGlass.frame = CGRect(x: t.composerSideInset, y: bounds.height - 4 - (t.composerMinHeight + plusSize) / 2 + 1, width: plusSize, height: plusSize)
        plusButton.frame = plusGlass.bounds
        let fieldX = plusGlass.frame.maxX + t.composerFieldGap
        fieldGlass.frame = CGRect(x: fieldX, y: bounds.height - 4 - fieldHeight, width: bounds.width - fieldX - t.composerSideInset + 1, height: fieldHeight)
        let field = fieldGlass.bounds
        var textTop: CGFloat = 0
        if !attachments.isEmpty {
            attachmentStrip.frame = CGRect(x: 0, y: 8, width: field.width, height: attachmentHeight)
            attachmentSeparator.frame = CGRect(x: 0, y: attachmentHeight + 16, width: field.width, height: 0.5)
            textTop = attachmentHeight + 16
            layoutAttachments()
        }
        let trailing = sendSize.width + 10
        textView.frame = CGRect(x: fieldTextInset, y: textTop, width: field.width - fieldTextInset - trailing, height: field.height - textTop)
        placeholder.frame = CGRect(x: fieldTextInset, y: textTop + verticalPadding, width: textView.bounds.width, height: ConversationTheme.lineHeight)
        sendButton.bounds = CGRect(origin: .zero, size: sendSize)
        sendButton.center = CGPoint(x: field.width - 4 - sendSize.width / 2, y: field.height - t.composerMinHeight / 2)
        micButton.frame = CGRect(x: field.width - 40, y: field.height - t.composerMinHeight, width: 34, height: t.composerMinHeight)
        fieldGlass.layer.cornerRadius = min(fieldHeight, t.composerMinHeight) / 2
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        fieldGlass.layer.borderColor = UIColor.separator.resolvedColor(with: traitCollection).cgColor
    }

    // MARK: Text

    func textViewDidChange(_ textView: UITextView) {
        textDidChange()
    }

    private func textDidChange() {
        updatePlaceholder()
        updateSendButton(animated: true)
        updateHeight()
        delegate?.composerDidChangeText(self)
    }

    private func updatePlaceholder() {
        placeholder.text = !attachments.isEmpty
            ? String(localized: "conversation.composer.addComment", defaultValue: "Add comment or Send", bundle: .module)
            : (isReplyMode ? replyPlaceholderText : placeholderText)
        placeholder.isHidden = !(textView.text ?? "").isEmpty
    }

    private func updateSendButton(animated: Bool) {
        let show = hasContent
        let apply = {
            self.sendButton.alpha = show ? 1 : 0
            self.sendButton.transform = show ? .identity : CGAffineTransform(scaleX: 0.4, y: 0.4)
            self.micButton.alpha = show ? 0 : 1
        }
        guard animated, (sendButton.alpha == 1) != show else { apply(); return }
        UIView.animate(withDuration: 0.32, delay: 0, usingSpringWithDamping: 0.72, initialSpringVelocity: 0, options: [.beginFromCurrentState, .allowUserInteraction], animations: apply)
    }

    /// Grows by whole lines in the same frame as the edit, with no animation.
    func updateHeight() {
        let width = max(1, (fieldGlass.bounds.width > 0 ? fieldGlass.bounds.width : bounds.width - 120) - fieldTextInset - sendSize.width - 10)
        let textSize = textView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        let lines = max(1, round((textSize.height - 2 * verticalPadding) / ConversationTheme.lineHeight))
        var natural = ConversationTheme.composerMinHeight + (lines - 1) * ConversationTheme.lineHeight
        if !attachments.isEmpty { natural += attachmentHeight + 16 }
        let height = min(natural, maximumFieldHeight)
        textView.isScrollEnabled = natural > maximumFieldHeight
        guard height != fieldHeight else { return }
        fieldHeight = height
        UIView.performWithoutAnimation {
            self.setNeedsLayout()
            self.layoutIfNeeded()
        }
        delegate?.composerDidChangeHeight(self)
        if textView.isScrollEnabled {
            textView.scrollRangeToVisible(textView.selectedRange)
        }
    }

    // MARK: Attachments

    func addAttachment(_ attachment: ComposerAttachment) {
        attachments.append(attachment)
        attachmentsChanged()
    }

    func removeAttachment(id: UUID) {
        attachments.removeAll { $0.id == id }
        attachmentsChanged()
    }

    private func attachmentsChanged() {
        attachmentViews.forEach { $0.removeFromSuperview() }
        attachmentViews = attachments.map { attachment in
            let container = UIView()
            let imageView = UIImageView(image: attachment.image)
            imageView.contentMode = .scaleAspectFill
            imageView.clipsToBounds = true
            imageView.layer.cornerRadius = 12
            imageView.layer.cornerCurve = .continuous
            container.addSubview(imageView)
            let close = UIButton(type: .custom)
            close.setImage(UIImage(systemName: "xmark.circle.fill", withConfiguration: UIImage.SymbolConfiguration(paletteColors: [.white, UIColor.black.withAlphaComponent(0.55)])), for: .normal)
            close.accessibilityLabel = String(localized: "conversation.composer.removeAttachment", defaultValue: "Remove attachment", bundle: .module)
            let id = attachment.id
            close.addAction(UIAction { [weak self] _ in self?.removeAttachment(id: id) }, for: .touchUpInside)
            container.addSubview(close)
            attachmentStrip.addSubview(container)
            return container
        }
        attachmentStrip.isHidden = attachments.isEmpty
        attachmentSeparator.isHidden = attachments.isEmpty
        updatePlaceholder()
        updateSendButton(animated: true)
        setNeedsLayout()
        updateHeight()
        layoutIfNeeded()
    }

    private func layoutAttachments() {
        var x: CGFloat = 12
        for (index, view) in attachmentViews.enumerated() {
            let image = attachments[index].image
            let aspect = image.size.width / max(image.size.height, 1)
            let width = min(220, max(70, attachmentHeight * aspect))
            view.frame = CGRect(x: x, y: 0, width: width, height: attachmentHeight)
            view.subviews.first?.frame = view.bounds
            view.subviews.last?.frame = CGRect(x: width - 30, y: 4, width: 26, height: 26)
            x += width + 8
        }
        attachmentStrip.contentSize = CGSize(width: x + 4, height: attachmentHeight)
    }

    func clearAfterSend() {
        attachments = []
        attachmentViews.forEach { $0.removeFromSuperview() }
        attachmentViews = []
        attachmentStrip.isHidden = true
        attachmentSeparator.isHidden = true
        textView.text = ""
        updatePlaceholder()
        updateSendButton(animated: true)
        let previous = fieldHeight
        let width = max(1, fieldGlass.bounds.width - fieldTextInset - sendSize.width - 10)
        _ = width
        fieldHeight = ConversationTheme.composerMinHeight
        textView.isScrollEnabled = false
        guard previous != fieldHeight else {
            delegate?.composerDidChangeText(self)
            return
        }
        // Collapse with a slight spring undershoot, settling by ~0.38 s.
        // Measured against Messages' 40-line send: ~1.8% undershoot of the
        // drop (434 -> 35 pt min) rather than bounce 0.28's ~4% (26 pt).
        UIView.animate(springDuration: 0.31, bounce: 0.2, options: [.beginFromCurrentState]) {
            self.layoutSubviews()
            self.delegate?.composerDidChangeHeight(self)
        }
        delegate?.composerDidChangeText(self)
    }

    /// Field frame in `view`'s coordinates (for the send animation).
    func fieldFrame(in view: UIView) -> CGRect {
        fieldGlass.convert(fieldGlass.bounds, to: view)
    }

    func textFrame(in view: UIView) -> CGRect {
        textView.convert(textView.bounds, to: view)
    }
}

/// Return inserts a newline (Messages sends only from the button).
final class ComposerTextView: UITextView {
    override func paste(_ sender: Any?) {
        super.paste(sender)
        delegate?.textViewDidChange?(self)
    }
}
#endif
