#if canImport(UIKit)
import CmuxConversationCore
import CmuxConversationGeometry
import UIKit
import UniformTypeIdentifiers

/// A picked image (or, with `file`, a document) waiting in the composer.
struct ComposerAttachment {
    let id = UUID()
    var image: UIImage
    var data: Data
    var mimeType: String
    /// A document picked in Files: sent as a file. `image` is its rendered
    /// document chip, so the attachment card shows it like any preview.
    var file: ConversationPendingFile? = nil

    init(image: UIImage, data: Data, mimeType: String) {
        self.image = image
        self.data = data
        self.mimeType = mimeType
    }

    init(file: ConversationPendingFile, chip: UIImage) {
        self.image = chip
        self.data = file.data
        self.mimeType = file.info.mimeType
        self.file = file
    }
}

/// A queued attachment's bytes as a local file Quick Look can open before
/// it is sent: a document keeps its name, a photo is "Photo.<ext>".
struct ComposerAttachmentFile: Sendable {
    let id: UUID
    let data: Data
    let name: String

    init(_ attachment: ComposerAttachment) {
        id = attachment.id
        data = attachment.data
        let ext = UTType(mimeType: attachment.mimeType)?.preferredFilenameExtension ?? "jpg"
        let safe = (attachment.file?.info.name ?? "Photo.\(ext)").replacingOccurrences(of: "/", with: "-")
        name = safe.isEmpty || safe == "." || safe == ".." ? "Attachment" : safe
    }

    func write() -> URL? {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConversationComposerAttachments", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
        let target = folder.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: target.path) { return target }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: target, options: .atomic)
            return target
        } catch {
            return nil
        }
    }
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

    let plusButton = ComposerPlusButton(type: .system)
    private let plusGlass = makeGlassView(cornerRadius: ConversationTheme.plusButtonSize / 2, interactive: true, clipsContent: false)
    let fieldGlass = makeGlassView(cornerRadius: ConversationTheme.composerFieldCornerRadius, interactive: false, clipsContent: false)
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
        let textView = ComposerTextView(frame: .zero, textContainer: container)
        manager.delegate = textView.linePitch
        return textView
    }()
    /// Shown in place of the keyboard by the edit menu's Text Effects item.
    private(set) lazy var textEffectsPalette = TextEffectsPaletteView(composer: self)
    let placeholder = UILabel()
    let sendButton = UIButton(type: .custom)
    let micButton = UIButton(type: .system)
    /// While set the draft takes no edits (Send with effect shows it).
    var holdsDraft = false
    /// Queued photos above the text row (Messages' photo shelf).
    let attachmentShelf = ComposerAttachmentShelf()
    private(set) var attachments: [ComposerAttachment] = []
    /// A preview's remove button was tapped (after the attachment is dropped).
    var onRemoveAttachment: ((UUID) -> Void)?
    /// A queued attachment was tapped: preview it (the view it zooms from).
    var onOpenAttachment: ((UUID, UIView) -> Void)?
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
    var isReplyMode = false {
        didSet {
            updatePlaceholder()
            updateSendLabel()
        }
    }
    /// Editing one of my messages: the send button becomes a checkmark.
    var isEditMode = false {
        didSet {
            let symbol = isEditMode ? "checkmark" : "arrow.up"
            sendButton.setImage(UIImage(systemName: symbol, withConfiguration: Self.sendSymbolConfiguration), for: .normal)
            updateSendLabel()
        }
    }

    /// Messages names the button for what it sends: "Send Reply" in a reply thread.
    private func updateSendLabel() {
        sendButton.accessibilityLabel = isEditMode
            ? String(localized: "conversation.composer.saveEdit", defaultValue: "Save Edit", bundle: .module)
            : isReplyMode
            ? String(localized: "conversation.composer.sendReply", defaultValue: "Send Reply", bundle: .module)
            : String(localized: "conversation.composer.send", defaultValue: "Send", bundle: .module)
    }

    /// Edge inset of the + button and field with no keyboard: Messages'
    /// 28 pt concentric padding, or the keyboard inset while the Photos
    /// drawer stands in for the keyboard.
    var sideInset: CGFloat = ComposerBarGeometry.restSideInset { didSet { setNeedsLayout() } }
    /// Edge inset with the keyboard up: the system layout margin (16 pt on
    /// a 402 pt iPhone, 20 pt on a 440 pt one), set by the controller.
    var keyboardSideInset: CGFloat = 16 { didSet { if oldValue != keyboardSideInset { setNeedsLayout() } } }
    /// Send Later: the time chip at the top of the field, and its time.
    let sendLaterChip = SendLaterChipView()
    private(set) var sendLaterDate: Date?
    var onSendLaterEdit: (() -> Void)?
    var onSendLaterClose: (() -> Void)?
    private var sendLaterHeight: CGFloat { sendLaterDate == nil ? 0 : SendLaterChipView.height + 10 }

    private(set) var fieldHeight: CGFloat = ConversationTheme.composerMinHeight
    /// The text width the draft was last measured at.
    private var measurement = ComposerFieldMeasurement()
    /// Messages' photo shelf: 155 pt previews inset 6 pt, then a 1 pt divider.
    private var attachmentBand: CGFloat { ComposerAttachmentShelfGeometry.bandHeight }
    /// How far the keyboard has risen (0 hidden, 1 fully shown). Messages
    /// widens the composer as the keyboard rises: both side insets move from
    /// `sideInset` to `keyboardSideInset`, in step with the keyboard.
    var keyboardProgress: CGFloat = 0 {
        didSet { if oldValue != keyboardProgress { setNeedsLayout() } }
    }
    private let verticalPadding = ConversationTheme.composerTextPadding
    private let fieldTextInset = ComposerBarGeometry.textLeadingInset
    private let sendSize = ComposerBarGeometry.sendSize
    static var isIOS27: Bool {
        if #available(iOS 27, *) { return true }
        return false
    }

    /// Messages' send blue: system blue for the appearance and contrast
    /// alone (0,145,255 dark, 0,136,255 light). The composer's scroll edge
    /// element container adapts other traits for legibility, under which
    /// plain system blue drew 16,138,255 in dark mode.
    static let sendBlue = UIColor.resolving { traits in
        UIColor.systemBlue.resolvedColor(with: UITraitCollection(traitsFrom: [
            UITraitCollection(userInterfaceStyle: traits.userInterfaceStyle),
            UITraitCollection(accessibilityContrast: traits.accessibilityContrast),
        ]))
    }
    /// Messages' "+" glyph (see `ComposerBarGeometry.plusSymbolPointSize`).
    static let plusSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: ComposerBarGeometry.plusSymbolPointSize, weight: .regular, scale: .medium)
    /// Messages' send arrow: `arrow.up`, bold, 13 by 16 pt of ink.
    static let sendSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: ComposerBarGeometry.sendSymbolPointSize, weight: .bold, scale: .medium)

    var text: String {
        get { textView.text ?? "" }
        set {
            textView.text = newValue
            mentionController.reset()
            textDidChange()
        }
    }

    /// The "+" glass circle, for the apps menu to morph out of and back into.
    func plusGlassFrame(in view: UIView) -> CGRect {
        plusGlass.convert(plusGlass.bounds, to: view)
    }

    /// Hidden while the apps menu has taken the "+" circle's place.
    var isPlusGlassHidden: Bool {
        get { plusGlass.isHidden }
        set { plusGlass.isHidden = newValue }
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
        plusButton.setImage(UIImage(systemName: "plus", withConfiguration: Self.plusSymbolConfiguration), for: .normal)
        plusButton.tintColor = .label
        // Disabled (New Message before a recipient) Messages draws the plus
        // lighter than UIKit's own dimming (137 on the light glass).
        let disabledInk: UIColor = switch ComposerBarGeometry.disabledPlusInk(iOS27: Self.isIOS27) {
        case .tertiaryHue(let lightAlpha, let darkAlpha): UIColor.resolving { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 235 / 255, green: 235 / 255, blue: 245 / 255, alpha: darkAlpha)
                : UIColor(red: 60 / 255, green: 60 / 255, blue: 67 / 255, alpha: lightAlpha)
        }
        }
        plusButton.setImage(UIImage(systemName: "plus", withConfiguration: Self.plusSymbolConfiguration)?.withTintColor(disabledInk, renderingMode: .alwaysOriginal), for: .disabled)
        plusButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.delegate?.composerDidTapPlus(self)
        }, for: .touchUpInside)
        plusButton.accessibilityLabel = String(localized: "conversation.ax.composerPlus", defaultValue: "Add", bundle: .module)
        plusButton.accessibilityHint = String(localized: "conversation.ax.composerPlus.hint", defaultValue: "Add photos or apps to this conversation", bundle: .module)
        plusButton.accessibilityIdentifier = "conversation.composer.plus"

        addSubview(fieldGlass)
        // Liquid Glass draws its own rim; Messages' field has no stroke
        // (ChatKit `entryFieldBorderWidth` 0). The blur fallback needs one.
        if #unavailable(iOS 26.0) {
            fieldGlass.layer.borderWidth = 0.5
            fieldGlass.layer.borderColor = UIColor.separator.cgColor
        }
        fieldGlass.contentView.addSubview(attachmentShelf)
        fieldGlass.contentView.addSubview(linkPreview.container)
        linkPreview.onChange = { [weak self] in
            self?.setNeedsLayout()
            self?.updateHeight()
        }
        attachmentShelf.isHidden = true
        attachmentShelf.onRemove = { [weak self] id in
            self?.removeAttachment(id: id)
            self?.onRemoveAttachment?(id)
        }
        attachmentShelf.onOpen = { [weak self] id, view in self?.onOpenAttachment?(id, view) }

        textView.font = ConversationTheme.bodyFont
        textView.baseTypingAttributes = [
            .font: ConversationTheme.bodyFont,
            .foregroundColor: UIColor.label,
            .paragraphStyle: ConversationTheme.composerParagraph,
        ]
        textView.typingAttributes = textView.baseTypingAttributes
        textView.installTextEffects()
        textView.onFormattingChanged = { [weak self] in self?.formattingDidChange() }
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: verticalPadding, left: 0, bottom: verticalPadding, right: 0)
        textView.textContainer.lineFragmentPadding = 0
        textView.isScrollEnabled = false
        textView.delegate = self
        // The keyboard's Return starts a new line (as in Messages); a hardware
        // keyboard's Return sends and Shift- or Option-Return starts a new line.
        textView.returnKeyType = .default
        textView.onHardwareReturn = { [weak self] in
            guard let self, self.hasContent, !self.holdsDraft else { return }
            self.delegate?.composerDidTapSend(self)
        }
        // A copied image or file pasted into the field (edit menu Paste or
        // Command-V) is attached as Photos or Files would attach it, while
        // "+" takes attachments (Chief turns it off until it takes sends).
        textView.acceptsAttachments = { [weak self] in self?.plusButton.isEnabled == true }
        textView.onPasteAttachments = { [weak self] in self?.pasteAttachments() }
        textView.accessibilityIdentifier = "conversation.composer.text"
        // Messages: a text field labeled "Message" whose value is the placeholder while empty.
        textView.accessibilityLabel = String(localized: "conversation.ax.composerField", defaultValue: "Message", bundle: .module)
        fieldGlass.contentView.addSubview(textView)
        _ = mentionController

        placeholder.font = ConversationTheme.bodyFont
        placeholder.textColor = .placeholderText
        placeholder.isUserInteractionEnabled = false
        placeholder.isAccessibilityElement = false
        // Over the field glass rather than in its content view, which is
        // its own blending group: there a compositing filter only meets the
        // clear content view (`ConversationTheme.composerInkCompositing`).
        insertSubview(placeholder, aboveSubview: fieldGlass)
        updatePlaceholder()

        sendButton.backgroundColor = Self.sendBlue
        sendButton.setImage(UIImage(systemName: "arrow.up", withConfiguration: Self.sendSymbolConfiguration), for: .normal)
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
        // Over the field rather than in the glass's content view, where the
        // capsule read 13,158,255 (iOS 26) and 19,164,255 (27) in dark mode
        // against Messages' 0,145,255.
        addSubview(sendButton)

        micButton.setImage(UIImage(systemName: "mic", withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .regular)), for: .normal)
        micButton.tintColor = ConversationTheme.composerMicTint
        // Pin the 17 pt symbol (Messages' microphone ink is 11.3 x 17.3 pt at
        // every text size); left alone the button drew it 1.3x larger. Only
        // the size: the record waveform keeps its own semibold weight.
        micButton.setPreferredSymbolConfiguration(UIImage.SymbolConfiguration(pointSize: 17), forImageIn: .normal)
        micButton.isUserInteractionEnabled = false
        micButton.isAccessibilityElement = false
        insertSubview(micButton, aboveSubview: placeholder)
        if ComposerBarGeometry.showsRecordGlyph(iOS27: Self.isIOS27, sentAudio: false) { showRecordGlyph() }
        applyInkCompositing()

        sendLaterChip.isHidden = true
        sendLaterChip.onEdit = { [weak self] in self?.onSendLaterEdit?() }
        sendLaterChip.onClose = { [weak self] in self?.onSendLaterClose?() }
        fieldGlass.contentView.addSubview(sendLaterChip)
    }

    /// Messages' record-audio waveform in place of the microphone
    /// (`ComposerBarGeometry.showsRecordGlyph`).
    func showRecordGlyph() {
        micButton.setImage(Self.recordGlyph, for: .normal)
    }

    /// `ComposerBarGeometry.recordGlyphBars` as a template image.
    private static let recordGlyph: UIImage = {
        let side = ComposerBarGeometry.recordGlyphSide
        let image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { _ in
            UIColor.black.setFill()
            for bar in ComposerBarGeometry.recordGlyphBars {
                UIBezierPath(roundedRect: bar, cornerRadius: bar.width / 2).fill()
            }
        }
        return image.withRenderingMode(.alwaysTemplate)
    }()

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
        let sideInset = ComposerBarGeometry.sideInset(keyboardProgress: keyboardProgress, restInset: self.sideInset, keyboardInset: keyboardSideInset)
        let row = ComposerBarGeometry.layout(
            width: bounds.width, fieldBottom: bounds.height - 4, fieldHeight: fieldHeight,
            oneLineHeight: t.composerMinHeight, sideInset: sideInset, scale: traitCollection.displayScale
        )
        plusGlass.frame = row.plus
        plusButton.frame = plusGlass.bounds
        fieldGlass.frame = row.field
        let field = fieldGlass.bounds
        var textTop: CGFloat = sendLaterHeight
        if sendLaterDate != nil {
            let chip = sendLaterChip.sizeThatFits(CGSize(width: field.width - 20, height: SendLaterChipView.height))
            UIView.performWithoutAnimation {
                sendLaterChip.bounds.size = chip
                sendLaterChip.center = CGPoint(x: 8 + chip.width / 2, y: 8 + chip.height / 2)
            }
        }
        attachmentShelf.frame = CGRect(x: 0, y: textTop, width: field.width, height: attachments.isEmpty ? 0 : attachmentBand)
        textTop += attachmentShelf.frame.height
        if linkPreview.preview != nil {
            linkPreview.layout(fieldWidth: field.width)
            linkPreview.container.frame.origin.y = textTop
            textTop += linkPreview.container.frame.height
        }
        let trailing = sendSize.width + 10
        // The full-width shelf and link card, the Send Later chip and
        // scrolled text reach the rounded corners; only then does the glass
        // clip (it costs an offscreen pass each frame behind it moves).
        let reachesCorners = !attachments.isEmpty || linkPreview.preview != nil || sendLaterDate != nil || textView.isScrollEnabled
        if #available(iOS 26.0, *) {
            let clips = ConversationGlassClipping.clipsToBounds(liquidGlass: true, contentReachesCorners: reachesCorners)
            if fieldGlass.clipsToBounds != clips { fieldGlass.clipsToBounds = clips }
        }
        // TextKit 1 checks that a line fits before `ComposerLinePitch` takes
        // the leading off it, so the text view reaches that much past the
        // field's bottom padding; otherwise it drops the last line.
        let lineSlack = max(0, -ConversationTheme.composerLineLeading)
        textView.frame = CGRect(x: fieldTextInset, y: textTop, width: field.width - fieldTextInset - trailing, height: field.height - textTop + lineSlack)
        placeholder.frame = CGRect(x: fieldTextInset, y: textTop + verticalPadding, width: textView.bounds.width, height: ConversationTheme.lineHeight)
            .offsetBy(dx: row.field.minX, dy: row.field.minY)
        sendButton.bounds = CGRect(origin: .zero, size: sendSize)
        sendButton.center = CGPoint(x: row.field.minX + row.send.midX, y: row.field.minY + row.send.midY)
        // Messages centers the glyph 21 pt in from the field's end, on the
        // plus's row and the pixel grid.
        let glyph = ComposerBarGeometry.recordGlyphFrame(
            fieldBottom: row.field.minY + field.height, fieldTrailing: row.field.minX + field.width, scale: traitCollection.displayScale
        )
        micButton.frame = glyph.insetBy(dx: -6, dy: -9)
        // A fixed 20 pt continuous corner, not a capsule: the field keeps it
        // when larger text makes it 68 pt tall (Messages, iOS 26.5 at AX3).
        fieldGlass.layer.cornerRadius = min(fieldHeight / 2, ConversationTheme.composerFieldCornerRadius)
        // A draft measured at another width (keyboard insets, reply mode,
        // the Photos drawer, rotation, a first pass before layout) wraps
        // differently here: measure it again.
        if field.width > 0, measurement.needsRemeasure(textWidth: textWidth(forFieldWidth: field.width)) {
            updateHeight()
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        fieldGlass.layer.borderColor = UIColor.separator.resolvedColor(with: traitCollection).cgColor
        applyInkCompositing()
        if traitCollection.changesTextMetrics(from: previousTraitCollection) {
            applyScaledFonts()
        }
    }

    /// The placeholder and microphone blend into the field as Messages'
    /// do (`ConversationTheme.composerInkCompositing`).
    private func applyInkCompositing() {
        let filter = ConversationTheme.composerInkCompositing(traitCollection)
        placeholder.layer.compositingFilter = filter
        micButton.layer.compositingFilter = filter
    }

    /// The field's text and placeholder follow Dynamic Type; the field grows with them.
    private func applyScaledFonts() {
        textView.font = ConversationTheme.bodyFont
        textView.typingAttributes = [
            .font: ConversationTheme.bodyFont,
            .foregroundColor: UIColor.label,
            .paragraphStyle: ConversationTheme.composerParagraph,
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

    func textViewDidEndEditing(_ textView: UITextView) {
        // The next focus brings the keyboard, not the Text Effects palette.
        self.textView.inputView = nil
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
        return ConversationTheme.emojiOnlyFontSize(count: text.count)
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
            .paragraphStyle: ConversationTheme.composerParagraph,
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

    /// Grows by whole lines in the same frame as the edit, with no animation;
    /// The text column inside a field `fieldWidth` wide (the send button's
    /// column is kept clear on the trailing side).
    private func textWidth(forFieldWidth fieldWidth: CGFloat) -> CGFloat {
        max(1, fieldWidth - fieldTextInset - sendSize.width - 10)
    }

    /// `animated` (the photo shelf opening or closing) moves on the shelf spring.
    func updateHeight(animated: Bool = false) {
        let width = textWidth(forFieldWidth: fieldGlass.bounds.width > 0 ? fieldGlass.bounds.width : bounds.width - 120)
        let textSize = textView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        measurement.didMeasure(textWidth: width)
        let leading = ConversationTheme.composerLineLeading
        let lines = ComposerFieldMeasurement.lineCount(textHeight: textSize.height, verticalPadding: verticalPadding, lineHeight: ConversationTheme.lineHeight, leading: leading)
        var natural = ComposerFieldMeasurement.fieldHeight(lines: lines, oneLineHeight: ConversationTheme.composerMinHeight, lineHeight: ConversationTheme.lineHeight, leading: leading)
        if emojiPointSize != nil { natural = max(ConversationTheme.composerMinHeight, ceil(textSize.height)) }
        if !attachments.isEmpty { natural += attachmentBand }
        natural += linkPreview.height(forFieldWidth: fieldGlass.bounds.width > 0 ? fieldGlass.bounds.width : bounds.width - 120)
        natural += sendLaterHeight
        let height = min(natural, maximumFieldHeight)
        textView.isScrollEnabled = natural > maximumFieldHeight
        guard height != fieldHeight else { return }
        fieldHeight = height
        guard !animated else {
            ComposerAttachmentShelf.animate {
                self.setNeedsLayout()
                self.layoutIfNeeded()
                self.delegate?.composerDidChangeHeight(self)
            }
            return
        }
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

    /// The pasteboard's images (each item's PNG or JPEG bytes as the copying
    /// app gave them, else re-encoded as PNG), or its copied files.
    private func pasteAttachments() {
        let board = UIPasteboard.general
        guard board.hasImages else {
            if let first = ComposerTextView.leadingType(board), ComposerTextView.isPastedFileType(first),
               !board.hasStrings || first.conforms(to: .image) {
                pasteFileData(board.itemProviders)
                return
            }
            for url in board.urls?.filter(\.isFileURL) ?? [] {
                Task { @MainActor [weak self] in
                    guard let traits = self?.traitCollection,
                          let attachment = await ConversationMediaDelegate.composerAttachment(for: url, traits: traits) else { return }
                    self?.addAttachment(attachment)
                }
            }
            return
        }
        let pasted: [ComposerAttachment] = (0..<board.numberOfItems).compactMap { index in
            let item = IndexSet(integer: index)
            let itemTypes = (board.types(forItemSet: item)?.first ?? []).compactMap { UTType($0) }
            guard let type = itemTypes.first(where: { $0.conforms(to: .image) }),
                  let data = board.data(forPasteboardType: type.identifier, inItemSet: item)?.first,
                  let image = UIImage(data: data) else { return nil }
            if type.conforms(to: .png) { return ComposerAttachment(image: image, data: data, mimeType: "image/png") }
            if type.conforms(to: .jpeg) { return ComposerAttachment(image: image, data: data, mimeType: "image/jpeg") }
            return image.pngData().map { ComposerAttachment(image: image, data: $0, mimeType: "image/png") }
        }
        guard pasted.isEmpty else {
            pasted.forEach(addAttachment)
            return
        }
        for image in board.images ?? [] {
            if let png = image.pngData() { addAttachment(ComposerAttachment(image: image, data: png, mimeType: "image/png")) }
        }
    }

    /// A file copied in Files is its bytes on the pasteboard, not a path:
    /// each is copied (off the main thread) under its own name, then attached
    /// as the Files picker attaches a file. The copy goes once it is attached.
    private func pasteFileData(_ providers: [NSItemProvider]) {
        for provider in providers {
            guard let type = provider.registeredTypeIdentifiers.lazy.compactMap({ UTType($0) })
                .first(where: { ComposerTextView.isPastedFileType($0) }) else { continue }
            var name = (provider.suggestedName ?? "").replacingOccurrences(of: "/", with: "-")
            if name.isEmpty || name == "." || name == ".." {
                name = String(localized: "conversation.composer.pastedFile", defaultValue: "Pasted file", bundle: .module)
            }
            if let ext = type.preferredFilenameExtension, (name as NSString).pathExtension.isEmpty { name += ".\(ext)" }
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("ConversationComposerPaste", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            let target = folder.appendingPathComponent(name)
            _ = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
                // The provider's file exists only during this call, on its own queue.
                guard let url, (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil,
                      (try? FileManager.default.copyItem(at: url, to: target)) != nil else { return }
                Task { @MainActor [weak self] in
                    defer { try? FileManager.default.removeItem(at: folder) }
                    guard let traits = self?.traitCollection,
                          let attachment = await ConversationMediaDelegate.composerAttachment(for: target, traits: traits) else { return }
                    self?.addAttachment(attachment)
                }
            }
        }
    }

    func addAttachment(_ attachment: ComposerAttachment) {
        attachments.append(attachment)
        let opening = attachments.count == 1
        if opening {
            // The shelf opens at the field's current top and is revealed as
            // the field grows (Messages pins the previews to the shelf top).
            UIView.performWithoutAnimation {
                attachmentShelf.frame = CGRect(x: 0, y: attachmentShelf.frame.minY, width: fieldGlass.bounds.width, height: 0)
                attachmentShelf.isHidden = false
                attachmentShelf.layoutIfNeeded()
            }
        }
        attachmentShelf.append(id: attachment.id, image: attachment.image, animated: window != nil)
        attachmentsChanged(shelfToggled: opening)
    }

    func removeAttachment(id: UUID) {
        guard attachments.contains(where: { $0.id == id }) else { return }
        attachments.removeAll { $0.id == id }
        // The last photo leaves at once and the field collapses around it.
        if attachments.isEmpty {
            attachmentShelf.removeAll()
            attachmentShelf.isHidden = true
        } else {
            attachmentShelf.remove(id: id, animated: window != nil)
        }
        attachmentsChanged(shelfToggled: attachments.isEmpty)
    }

    /// Messages swaps the placeholder and the send button at once; the field
    /// grows or collapses on the shelf spring when the shelf opens or closes.
    private func attachmentsChanged(shelfToggled: Bool) {
        updateEmojiScale()
        updatePlaceholder()
        updateSendButton(animated: false)
        setNeedsLayout()
        updateHeight(animated: shelfToggled && window != nil)
    }

    func clearAfterSend() {
        attachments = []
        attachmentShelf.removeAll()
        attachmentShelf.isHidden = true
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
        // Collapse on ChatKit's entry-view spring, logged on iOS 26.5 and
        // 27.0 (mass 2, stiffness 447, damping 49: response 0.4203 s,
        // bounce 0.1806).
        UIView.animate(springDuration: 0.4203, bounce: 0.1806, options: [.beginFromCurrentState]) {
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
/// Lines after the first step by the font's line height plus its leading,
/// as TextKit 2 lays them out in Messages' field: the tight-leading body
/// font is 20.29 pt with -0.29 pt leading, so the field grows 20 pt a line.
/// TextKit 1 (which the effect overlay needs) drops a negative leading, so
/// each later line fragment moves up by it here; the first line, and so the
/// one-line field and its text, stay as they are.
final class ComposerLinePitch: NSObject, NSLayoutManagerDelegate {
    func layoutManager(
        _ layoutManager: NSLayoutManager,
        shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<CGRect>,
        lineFragmentUsedRect: UnsafeMutablePointer<CGRect>,
        baselineOffset: UnsafeMutablePointer<CGFloat>,
        in textContainer: NSTextContainer,
        forGlyphRange glyphRange: NSRange
    ) -> Bool {
        guard glyphRange.location > 0, let storage = layoutManager.textStorage, storage.length > 0 else { return false }
        let index = min(layoutManager.characterIndexForGlyph(at: glyphRange.location), storage.length - 1)
        guard let font = storage.attribute(.font, at: index, effectiveRange: nil) as? UIFont, font.leading < 0 else { return false }
        // The leading comes off above the line, as TextKit 2 places it:
        // baselines 20 pt apart from the first line on.
        lineFragmentRect.pointee.origin.y += font.leading
        lineFragmentUsedRect.pointee.origin.y += font.leading
        return true
    }
}

final class ComposerTextView: UITextView {
    /// The layout manager's delegate (it holds it weakly).
    let linePitch = ComposerLinePitch()

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

    /// A hardware keyboard's Return (no modifier): send. Shift- and Option-Return
    /// insert a line break; while text is being composed (marked text) Return
    /// belongs to the input method.
    var onHardwareReturn: (() -> Void)?

    override var keyCommands: [UIKeyCommand]? {
        var commands: [UIKeyCommand] = [
            UIKeyCommand(input: "b", modifierFlags: .command, action: #selector(toggleBoldface(_:))),
            UIKeyCommand(input: "i", modifierFlags: .command, action: #selector(toggleItalics(_:))),
            UIKeyCommand(input: "u", modifierFlags: .command, action: #selector(toggleUnderline(_:))),
        ]
        if onHardwareReturn != nil {
            commands += [
                UIKeyCommand(input: "\r", modifierFlags: [], action: #selector(hardwareReturn)),
                UIKeyCommand(input: "\r", modifierFlags: .shift, action: #selector(hardwareLineBreak)),
                UIKeyCommand(input: "\r", modifierFlags: .alternate, action: #selector(hardwareLineBreak)),
            ]
        }
        commands.forEach { $0.wantsPriorityOverSystemBehavior = true }
        return (super.keyCommands ?? []) + commands
    }

    @objc private func hardwareReturn() { onHardwareReturn?() }

    @objc private func hardwareLineBreak() {
        insertText("\n")
        scrollRangeToVisible(selectedRange)
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(hardwareReturn) || action == #selector(hardwareLineBreak) {
            return isEditable && markedTextRange == nil
        }
        if action == #selector(toggleBoldface(_:)) || action == #selector(toggleItalics(_:)) || action == #selector(toggleUnderline(_:)) {
            return isEditable
        }
        if action == #selector(paste(_:)), pastesAttachments {
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

    /// Takes a pasted image or copied file. A plain text view offers no Paste
    /// for an image; this one does while `acceptsAttachments`. The paste is
    /// the person's own action, so reading the pasteboard asks nothing.
    var onPasteAttachments: (() -> Void)?
    var acceptsAttachments: () -> Bool = { false }

    /// An image or a copied file leads the pasteboard, and the composer takes
    /// one now. Text that came with an image (cells from Numbers, a note with
    /// a picture) still pastes as text. Reading the types asks nothing.
    private var pastesAttachments: Bool {
        guard onPasteAttachments != nil, acceptsAttachments() else { return false }
        let board = UIPasteboard.general
        // An image copied as an image object (Photos, Safari) leads with
        // UIKit's private `com.apple.uikit.image`, not an image type.
        if board.hasImages, !board.hasStrings { return true }
        // The first declared type, past an app's private ones: Files leads with
        // `com.apple.DocumentManager.FINode.File`, then the file's own type.
        guard let first = Self.leadingType(board) else { return board.hasImages }
        if first.conforms(to: .fileURL) { return true }
        if first.conforms(to: .image) { return board.hasImages || Self.isPastedFileType(first) }
        guard !board.hasStrings else { return false }
        return board.contains(pasteboardTypes: [UTType.fileURL.identifier]) || Self.isPastedFileType(first)
    }

    /// A copied file's own type (Files' Copy puts the file's bytes, a PDF or
    /// an archive): declared, and not text, a web link or an app's private format.
    static func leadingType(_ board: UIPasteboard) -> UTType? {
        board.types.lazy.compactMap { UTType($0) }.first(where: \.isDeclared)
    }

    /// The same rule as CmuxMobileDesign's `UIPasteboard.isComposerFileType`
    /// (another package).
    static func isPastedFileType(_ type: UTType) -> Bool {
        guard type.isDeclared, !type.isDynamic else { return false }
        if type.conforms(to: .image) { return true }
        let prose: [UTType] = [.text, .url, .rtfd, .flatRTFD, .webArchive]
        if prose.contains(where: { type.conforms(to: $0) }) { return false }
        return type.conforms(to: .data) || type.conforms(to: .package)
    }

    override func paste(_ sender: Any?) {
        if pastesAttachments, let onPasteAttachments {
            onPasteAttachments()
            return
        }
        super.paste(sender)
        delegate?.textViewDidChange?(self)
    }
}
/// The "+" button: its glyph sits `ComposerBarGeometry.plusGlyphOffsetY`
/// from the circle's center while the button (and its accessibility frame)
/// covers the whole circle.
final class ComposerPlusButton: UIButton {
    override func layoutSubviews() {
        super.layoutSubviews()
        let offset = ComposerBarGeometry.plusGlyphOffsetY(iOS27: ConversationComposerView.isIOS27)
        guard offset != 0, let imageView, imageView.image != nil else { return }
        imageView.center.y = bounds.midY + offset
    }
}
#endif
