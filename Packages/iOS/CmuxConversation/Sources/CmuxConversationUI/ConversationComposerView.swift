#if canImport(UIKit)
import CmuxConversationCore
import CmuxConversationGeometry
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
    /// Long press on send: "Send with effect".
    func composerDidLongPressSend(_ composer: ConversationComposerView)
}

/// Messages composer: a glass "+" circle and a glass capsule field that grows
/// one 24 pt line at a time (no animation), up to `maximumFieldHeight`, then
/// scrolls. The send button lives inside the field and appears with content.
final class ConversationComposerView: UIView, UITextViewDelegate {
    weak var delegate: (any ConversationComposerViewDelegate)?

    let plusButton = UIButton(type: .system)
    private let plusGlass = makeGlassView(cornerRadius: ConversationTheme.plusButtonSize / 2, interactive: true)
    let fieldGlass = makeGlassView(cornerRadius: ConversationTheme.composerMinHeight / 2, interactive: false)
    /// TextKit 1, so the effect overlay can read glyph geometry.
    /// (Built on an explicit stack: the `usingTextLayoutManager:` factory
    /// bypasses Swift's stored-property initialization in subclasses.)
    let textView: ComposerTextView = {
        let storage = NSTextStorage()
        let manager = NSLayoutManager()
        storage.addLayoutManager(manager)
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        manager.addTextContainer(container)
        return ComposerTextView(frame: .zero, textContainer: container)
    }()
    /// Shown in place of the keyboard by the edit menu's Text Effects item.
    private(set) lazy var textEffectsPalette = TextEffectsPaletteView(composer: self)
    let placeholder = UILabel()
    let sendButton = UIButton(type: .custom)
    let micButton = UIButton(type: .system)
    private let attachmentStrip = UIScrollView()
    private let attachmentSeparator = UIView()
    private var attachmentViews: [UIView] = []
    private(set) var attachments: [ComposerAttachment] = []
    /// A preview's remove button was tapped (after the attachment is dropped).
    var onRemoveAttachment: ((UUID) -> Void)?
    /// Mention ranges, the gray candidate and suggestions for the draft.
    private(set) lazy var mentionController = ComposerMentionController(textView: textView)
    /// Pending rich link card for a URL that opens or ends the draft.
    let linkPreview = ComposerLinkPreview()

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

    /// Edge inset of the + button and field. Messages pulls both to 16 pt
    /// while the Photos drawer is open (27 pt otherwise).
    var sideInset: CGFloat = ConversationTheme.composerSideInset { didSet { setNeedsLayout() } }
    /// Send Later: the time chip at the top of the field, and its time.
    let sendLaterChip = SendLaterChipView()
    private(set) var sendLaterDate: Date?
    var onSendLaterEdit: (() -> Void)?
    var onSendLaterClose: (() -> Void)?
    private var sendLaterHeight: CGFloat { sendLaterDate == nil ? 0 : SendLaterChipView.height + 10 }

    private(set) var fieldHeight: CGFloat = ConversationTheme.composerMinHeight
    // Messages' attachment card: 154 pt previews inset 6 pt, 6 pt apart, then a
    // separator inset 16 pt that sits 7 pt below them.
    private let attachmentHeight: CGFloat = 154
    private let attachmentInset: CGFloat = 6
    private let attachmentGap: CGFloat = 6
    private var attachmentBand: CGFloat { attachmentInset + attachmentHeight + 7 }
    /// How far the keyboard has risen (0 hidden, 1 fully shown). Messages
    /// widens the composer as the keyboard rises: both side insets shrink by
    /// 12 pt, in step with the keyboard (measured on iOS 26 Messages).
    var keyboardProgress: CGFloat = 0 {
        didSet { if oldValue != keyboardProgress { setNeedsLayout() } }
    }
    static let keyboardSideInsetReduction: CGFloat = 12
    private let verticalPadding = ConversationTheme.composerTextPadding
    private let fieldTextInset: CGFloat = 14.5
    private let sendSize = CGSize(width: 37, height: 28)

    var text: String {
        get { textView.text ?? "" }
        set {
            textView.text = newValue
            mentionController.reset()
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
        plusButton.accessibilityLabel = String(localized: "conversation.ax.composerPlus", defaultValue: "Add", bundle: .module)
        plusButton.accessibilityHint = String(localized: "conversation.ax.composerPlus.hint", defaultValue: "Add photos or apps to this conversation", bundle: .module)
        plusButton.accessibilityIdentifier = "conversation.composer.plus"

        addSubview(fieldGlass)
        fieldGlass.layer.borderWidth = 0.5
        fieldGlass.layer.borderColor = UIColor.separator.cgColor
        fieldGlass.contentView.addSubview(attachmentStrip)
        fieldGlass.contentView.addSubview(attachmentSeparator)
        fieldGlass.contentView.addSubview(linkPreview.container)
        linkPreview.onChange = { [weak self] in
            self?.setNeedsLayout()
            self?.updateHeight()
        }
        attachmentSeparator.backgroundColor = .separator
        attachmentStrip.showsHorizontalScrollIndicator = false
        attachmentStrip.isHidden = true
        attachmentSeparator.isHidden = true

        textView.font = ConversationTheme.bodyFont
        textView.baseTypingAttributes = [
            .font: ConversationTheme.bodyFont,
            .foregroundColor: UIColor.label,
            .paragraphStyle: ConversationTheme.bodyParagraph,
        ]
        textView.typingAttributes = textView.baseTypingAttributes
        textView.installTextEffects()
        textView.onFormattingChanged = { [weak self] in self?.formattingDidChange() }
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: verticalPadding, left: 0, bottom: verticalPadding, right: 0)
        textView.textContainer.lineFragmentPadding = 0
        textView.isScrollEnabled = false
        textView.delegate = self
        textView.returnKeyType = .default
        textView.accessibilityIdentifier = "conversation.composer.text"
        // Messages: a text field labeled "Message" whose value is the placeholder while empty.
        textView.accessibilityLabel = String(localized: "conversation.ax.composerField", defaultValue: "Message", bundle: .module)
        fieldGlass.contentView.addSubview(textView)
        _ = mentionController

        placeholder.font = ConversationTheme.bodyFont
        placeholder.textColor = .placeholderText
        placeholder.isUserInteractionEnabled = false
        placeholder.isAccessibilityElement = false
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
        let effectPress = UILongPressGestureRecognizer(target: self, action: #selector(sendLongPressed(_:)))
        effectPress.minimumPressDuration = 0.4
        sendButton.addGestureRecognizer(effectPress)
        sendButton.alpha = 0
        sendButton.transform = CGAffineTransform(scaleX: 0.4, y: 0.4)
        fieldGlass.contentView.addSubview(sendButton)

        micButton.setImage(UIImage(systemName: "mic", withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .regular)), for: .normal)
        micButton.tintColor = .secondaryLabel
        micButton.isUserInteractionEnabled = false
        micButton.isAccessibilityElement = false
        fieldGlass.contentView.addSubview(micButton)

        sendLaterChip.isHidden = true
        sendLaterChip.onEdit = { [weak self] in self?.onSendLaterEdit?() }
        sendLaterChip.onClose = { [weak self] in self?.onSendLaterClose?() }
        fieldGlass.contentView.addSubview(sendLaterChip)
    }

    /// Turns Send Later on (a date) or off (nil): the chip appears at the top
    /// of the field, which takes the Send Later fill and placeholder.
    func setSendLaterDate(_ date: Date?, animated: Bool) {
        let wasOn = sendLaterDate != nil
        sendLaterDate = date
        if let date {
            sendLaterChip.configure(date: date, animated: animated)
        }
        guard wasOn != (date != nil) else { setNeedsLayout(); return }
        sendLaterChip.isHidden = date == nil
        fieldGlass.contentView.backgroundColor = date == nil ? nil : SendLaterStyle.fieldFill
        updatePlaceholder()
        updateHeight()
        if animated, date != nil {
            sendLaterChip.alpha = 0
            sendLaterChip.transform = CGAffineTransform(scaleX: 0.85, y: 0.85)
            UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0) {
                self.sendLaterChip.alpha = 1
                self.sendLaterChip.transform = .identity
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let t = ConversationTheme.self
        let plusSize = t.plusButtonSize
        // The Photos drawer's inset, less Messages' widening as the keyboard rises.
        let sideInset = self.sideInset - Self.keyboardSideInsetReduction * keyboardProgress
        plusGlass.frame = CGRect(x: sideInset, y: bounds.height - 4 - (t.composerMinHeight + plusSize) / 2 + 1, width: plusSize, height: plusSize)
        plusButton.frame = plusGlass.bounds
        let fieldX = plusGlass.frame.maxX + t.composerFieldGap
        fieldGlass.frame = CGRect(x: fieldX, y: bounds.height - 4 - fieldHeight, width: bounds.width - fieldX - sideInset + 1, height: fieldHeight)
        let field = fieldGlass.bounds
        var textTop: CGFloat = sendLaterHeight
        if sendLaterDate != nil {
            let chip = sendLaterChip.sizeThatFits(CGSize(width: field.width - 20, height: SendLaterChipView.height))
            UIView.performWithoutAnimation {
                sendLaterChip.bounds.size = chip
                sendLaterChip.center = CGPoint(x: 8 + chip.width / 2, y: 8 + chip.height / 2)
            }
        }
        if !attachments.isEmpty {
            attachmentStrip.frame = CGRect(x: 0, y: textTop + attachmentInset, width: field.width, height: attachmentHeight)
            attachmentSeparator.frame = CGRect(x: 16, y: textTop + attachmentBand, width: field.width - 32, height: 0.5)
            textTop += attachmentBand
            layoutAttachments()
        }
        if linkPreview.preview != nil {
            linkPreview.layout(fieldWidth: field.width)
            linkPreview.container.frame.origin.y = textTop
            textTop += linkPreview.container.frame.height
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
        if traitCollection.changesTextMetrics(from: previousTraitCollection) {
            applyScaledFonts()
        }
    }

    /// The field's text and placeholder follow Dynamic Type; the field grows with them.
    private func applyScaledFonts() {
        textView.font = ConversationTheme.bodyFont
        textView.typingAttributes = [
            .font: ConversationTheme.bodyFont,
            .foregroundColor: UIColor.label,
            .paragraphStyle: ConversationTheme.bodyParagraph,
        ]
        if let text = textView.text, !text.isEmpty {
            let selection = textView.selectedRange
            textView.attributedText = NSAttributedString(string: text, attributes: textView.typingAttributes)
            textView.selectedRange = selection
        }
        placeholder.font = ConversationTheme.bodyFont
        fieldHeight = 0
        updateHeight()
        setNeedsLayout()
    }

    @objc private func sendLongPressed(_ press: UILongPressGestureRecognizer) {
        guard press.state == .began, hasContent, !isEditMode else { return }
        delegate?.composerDidLongPressSend(self)
    }

    // MARK: Text

    func textViewDidChange(_ textView: UITextView) {
        self.textView.restyle()
        textDidChange()
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        textEffectsPalette.refreshState()
        mentionController.selectionDidChange()
    }

    func textView(_ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
        let effects = UIAction(
            title: String(localized: "conversation.textEffects.title", defaultValue: "Text Effects", bundle: .module),
            image: UIImage(systemName: "textformat")
        ) { [weak self] _ in self?.showTextEffects() }
        var children = suggestedActions
        // After the standard Cut/Copy/Paste group, as Messages places it.
        children.insert(effects, at: min(1, children.count))
        return UIMenu(children: children)
    }

    /// Formatting of the draft, in the trimmed-later text's UTF-16 offsets.
    var textRuns: [ConversationTextRun] { textView.textRuns }

    /// Loads a draft with formatting (editing a sent message).
    func setText(_ text: String, runs: [ConversationTextRun]) {
        textView.setText(text, runs: runs)
        textDidChange()
    }

    func showTextEffects() {
        if !textView.isFirstResponder { textView.becomeFirstResponder() }
        textEffectsPalette.refreshState()
        textView.inputView = textEffectsPalette
        textView.reloadInputViews()
    }

    func hideTextEffects() {
        guard textView.inputView != nil else { return }
        textView.inputView = nil
        textView.reloadInputViews()
    }

    private func formattingDidChange() {
        textEffectsPalette.refreshState()
        textDidChange()
    }

    private func textDidChange() {
        updateEmojiScale()
        mentionController.textDidChange()
        updatePlaceholder()
        updateSendButton(animated: true)
        updateHeight()
        linkPreview.textChanged(text)
        delegate?.composerDidChangeText(self)
    }

    private func updatePlaceholder() {
        placeholder.text = !attachments.isEmpty
            ? String(localized: "conversation.composer.addComment", defaultValue: "Add comment or Send", bundle: .module)
            : sendLaterDate != nil
                ? String(localized: "conversation.sendLater.placeholder", defaultValue: "Send Later", bundle: .module)
                : (isReplyMode ? replyPlaceholderText : placeholderText)
        placeholder.isHidden = !(textView.text ?? "").isEmpty
        textView.accessibilityPlaceholder = placeholder.text
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

    /// Point size of an emoji-only draft, or nil for body text. Messages
    /// shows a lone emoji in the field at 72 pt and two or three at 48 pt
    /// (measured on iOS 26: glyph boxes 64 and 43 pt, a 105 pt field for one).
    private(set) var emojiPointSize: CGFloat?

    static func emojiPointSize(for text: String) -> CGFloat? {
        guard text == text.trimmingCharacters(in: .whitespacesAndNewlines),
              ConversationRowBuilder.isEmojiOnly(text) else { return nil }
        return text.count == 1 ? 72 : 48
    }

    private func updateEmojiScale() {
        guard textView.markedTextRange == nil else { return }
        let size = attachments.isEmpty ? Self.emojiPointSize(for: textView.text ?? "") : nil
        guard size != emojiPointSize else { return }
        emojiPointSize = size
        let attributes: [NSAttributedString.Key: Any] = size.map {
            [.font: UIFont.systemFont(ofSize: $0), .foregroundColor: UIColor.label]
        } ?? [
            .font: ConversationTheme.bodyFont,
            .foregroundColor: UIColor.label,
            .paragraphStyle: ConversationTheme.bodyParagraph,
        ]
        // Swap the draft's base; formatting keys and mentions stay and are
        // re-derived on the new base by the text view's restyle.
        textView.baseTypingAttributes = attributes
        let storage = textView.textStorage
        let full = NSRange(location: 0, length: storage.length)
        let selection = textView.selectedRange
        storage.beginEditing()
        storage.removeAttribute(.paragraphStyle, range: full)
        storage.addAttributes(attributes, range: full)
        storage.endEditing()
        textView.selectedRange = selection
        textView.restyle()
        textView.clearTypingDecorations()
    }

    /// Grows by whole lines in the same frame as the edit, with no animation.
    func updateHeight() {
        let width = max(1, (fieldGlass.bounds.width > 0 ? fieldGlass.bounds.width : bounds.width - 120) - fieldTextInset - sendSize.width - 10)
        let textSize = textView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        let lines = max(1, round((textSize.height - 2 * verticalPadding) / ConversationTheme.lineHeight))
        var natural = ConversationTheme.composerMinHeight + (lines - 1) * ConversationTheme.lineHeight
        if emojiPointSize != nil { natural = max(ConversationTheme.composerMinHeight, ceil(textSize.height)) }
        if !attachments.isEmpty { natural += attachmentBand }
        natural += linkPreview.height(forFieldWidth: fieldGlass.bounds.width > 0 ? fieldGlass.bounds.width : bounds.width - 120)
        natural += sendLaterHeight
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
            // A 19 pt neutral gray disc with a white cross (Messages), inside a
            // 32 pt hit target.
            let close = UIButton(type: .custom)
            let disc = UIView(frame: CGRect(x: 6.5, y: 6.5, width: 19, height: 19))
            disc.backgroundColor = UIColor(white: 0.46, alpha: 1)
            disc.layer.cornerRadius = 9.5
            disc.isUserInteractionEnabled = false
            let cross = UIImageView(image: UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 9, weight: .bold)))
            cross.tintColor = .white
            cross.contentMode = .center
            cross.frame = disc.bounds
            disc.addSubview(cross)
            close.addSubview(disc)
            close.accessibilityLabel = String(localized: "conversation.composer.removeAttachment", defaultValue: "Remove attachment", bundle: .module)
            let id = attachment.id
            close.addAction(UIAction { [weak self] _ in
                self?.removeAttachment(id: id)
                self?.onRemoveAttachment?(id)
            }, for: .touchUpInside)
            container.addSubview(close)
            attachmentStrip.addSubview(container)
            return container
        }
        attachmentStrip.isHidden = attachments.isEmpty
        attachmentSeparator.isHidden = attachments.isEmpty
        updateEmojiScale()
        updatePlaceholder()
        updateSendButton(animated: true)
        setNeedsLayout()
        updateHeight()
        layoutIfNeeded()
        // The newest pick scrolls into view; earlier ones clip at the card edge.
        let maxX = max(0, attachmentStrip.contentSize.width - attachmentStrip.bounds.width)
        attachmentStrip.setContentOffset(CGPoint(x: maxX, y: 0), animated: false)
    }

    private func layoutAttachments() {
        var x = attachmentInset
        let maxWidth = max(1, attachmentStrip.bounds.width - 2 * attachmentInset)
        for (index, view) in attachmentViews.enumerated() {
            let image = attachments[index].image
            let aspect = image.size.width / max(image.size.height, 1)
            let width = min(maxWidth, max(60, (attachmentHeight * aspect).rounded()))
            view.frame = CGRect(x: x, y: 0, width: width, height: attachmentHeight)
            view.subviews.first?.frame = view.bounds
            // The cross centers 13.3 pt in from the preview's top-right corner.
            view.subviews.last?.frame = CGRect(x: width - 13.3 - 16, y: 13.3 - 16, width: 32, height: 32)
            x += width + attachmentGap
        }
        attachmentStrip.contentSize = CGSize(width: x - attachmentGap + attachmentInset, height: attachmentHeight)
    }

    func clearAfterSend() {
        attachments = []
        attachmentViews.forEach { $0.removeFromSuperview() }
        attachmentViews = []
        attachmentStrip.isHidden = true
        attachmentSeparator.isHidden = true
        textView.text = ""
        mentionController.reset()
        textView.resetFormatting()
        hideTextEffects()
        updateEmojiScale()
        linkPreview.reset()
        updatePlaceholder()
        // Messages swaps send for the mic in the send frame; the flying
        // bubble starts translucent over the cleared field.
        updateSendButton(animated: false)
        let previous = fieldHeight
        let width = max(1, fieldGlass.bounds.width - fieldTextInset - sendSize.width - 10)
        _ = width
        fieldHeight = ConversationTheme.composerMinHeight + sendLaterHeight
        textView.isScrollEnabled = false
        guard previous != fieldHeight else {
            delegate?.composerDidChangeText(self)
            return
        }
        // Collapse on Messages' spring: fitted to iOS 26 Messages' field top
        // after an 8-line and a capped 40-line send (duration 0.40-0.41,
        // bounce 0.15-0.18; ~1.2% overshoot, settled by ~0.35 s).
        UIView.animate(springDuration: 0.4, bounce: 0.17, options: [.beginFromCurrentState]) {
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
    /// Gets the first chance at Delete (a mention deletes as one token).
    var deleteBackwardHandler: (() -> Bool)?

    override func deleteBackward() {
        if deleteBackwardHandler?() == true { return }
        super.deleteBackward()
    }

    /// Plain body attributes; formatting is layered on through the semantic keys.
    var baseTypingAttributes: [NSAttributedString.Key: Any] = [:]
    var onFormattingChanged: (() -> Void)?
    /// Draws non-semantic decorations (mention bold and colors) over the
    /// formatting each time it is re-derived, so both survive every restyle.
    var decorateStorage: ((NSTextStorage) -> Void)?
    let effectLayer = ConversationTextEffectLayer()

    override var keyCommands: [UIKeyCommand]? {
        let format: [UIKeyCommand] = [
            UIKeyCommand(input: "b", modifierFlags: .command, action: #selector(toggleBoldface(_:))),
            UIKeyCommand(input: "i", modifierFlags: .command, action: #selector(toggleItalics(_:))),
            UIKeyCommand(input: "u", modifierFlags: .command, action: #selector(toggleUnderline(_:))),
        ]
        format.forEach { $0.wantsPriorityOverSystemBehavior = true }
        return (super.keyCommands ?? []) + format
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(toggleBoldface(_:)) || action == #selector(toggleItalics(_:)) || action == #selector(toggleUnderline(_:)) {
            return isEditable
        }
        return super.canPerformAction(action, withSender: sender)
    }

    override func toggleBoldface(_ sender: Any?) { toggle(.bold) }
    override func toggleItalics(_ sender: Any?) { toggle(.italic) }
    override func toggleUnderline(_ sender: Any?) { toggle(.underline) }

    override func layoutSubviews() {
        super.layoutSubviews()
        refreshEffects()
    }

    /// Spoken as the value while empty, as a text field speaks its placeholder.
    var accessibilityPlaceholder: String?

    override var accessibilityValue: String? {
        get { (text ?? "").isEmpty ? accessibilityPlaceholder : super.accessibilityValue }
        set { super.accessibilityValue = newValue }
    }

    override func paste(_ sender: Any?) {
        super.paste(sender)
        delegate?.textViewDidChange?(self)
    }
}
#endif
