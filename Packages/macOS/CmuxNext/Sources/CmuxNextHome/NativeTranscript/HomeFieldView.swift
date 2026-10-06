import AppKit

/// The compose field: a Liquid Glass capsule holding a real NSTextView
/// (TextKit 2: IME, undo, spell checking, services). Return sends,
/// Option- or Shift-Return inserts a newline; marked text owns Return.
final class HomeFieldView: NSView {
    let glass = NSGlassEffectView()
    let textView = HomeFieldTextView(usingTextLayoutManager: true)
    private let placeholder = NSTextField(labelWithString: "")
    /// Draft attachments above the text, and the button that picks files.
    let tray = HomeDraftTrayView()
    let attachButton = NSButton()
    /// The glass's content: the glass sizes its content view to the field, so
    /// the text view, the tray and the attach button sit inside this holder
    /// at the field's insets (top-left origin).
    private let content = HomeFlippedView()
    private(set) var draftAttachments: [HomeDraftAttachment] = []
    /// Why an attachment was refused; cleared by the next edit, attach or send.
    private(set) var notice: String?
    private let noticeLabel = NSTextField(wrappingLabelWithString: "")
    /// Reports the new height after every edit (the host relayouts).
    var onHeightChange: () -> Void = {}
    var onSend: () -> Void = {}
    /// The attach button was clicked (the host opens the file picker).
    var onAttach: () -> Void = {}
    /// The host takes attachments from this pasteboard (paste, drop on the
    /// text); false leaves it to the text view.
    var onAttachmentPasteboard: (NSPasteboard) -> Bool = { _ in false }
    /// Attachments can be added (the data side is present).
    var attachEnabled = false {
        didSet {
            attachButton.isHidden = !attachEnabled
            needsLayout = true
        }
    }

    static let maxLines = 8
    /// The 13 pt reference metrics; `scale` multiplies them.
    static let baseFontSize: CGFloat = 13
    static let baseLineHeight: CGFloat = 16
    static let baseHorizontalInset: CGFloat = 12
    static let baseVerticalInset: CGFloat = 7

    /// The user's text size relative to 13 pt (the transcript's `textScale`).
    var scale: CGFloat = 1 {
        didSet {
            guard scale != oldValue else { return }
            applyFont()
            needsLayout = true
            onHeightChange()
        }
    }

    var lineHeight: CGFloat { (Self.baseLineHeight * scale).rounded() }
    var horizontalInset: CGFloat { (Self.baseHorizontalInset * scale).rounded() }
    var verticalInset: CGFloat { (Self.baseVerticalInset * scale).rounded() }

    func height(lines: Int) -> CGFloat { 2 * verticalInset + lineHeight * CGFloat(lines) + (lines >= 2 ? 1 : 0) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(glass)
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isContinuousSpellCheckingEnabled = true
        textView.writingToolsBehavior = .limited
        textView.textContainerInset = NSSize(width: 0, height: 0)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.onSend = { [weak self] in self?.onSend() }
        textView.onChange = { [weak self] in self?.textChanged() }
        textView.onAttachmentPasteboard = { [weak self] board in self?.onAttachmentPasteboard(board) ?? false }
        textView.setAccessibilityLabel(HomeStrings.messagePlaceholder)
        placeholder.stringValue = HomeStrings.messagePlaceholder
        placeholder.textColor = .placeholderTextColor
        content.addSubview(textView)
        content.addSubview(tray)
        content.addSubview(attachButton)
        content.addSubview(noticeLabel)
        noticeLabel.isHidden = true
        noticeLabel.font = .systemFont(ofSize: 11)
        noticeLabel.textColor = .secondaryLabelColor
        noticeLabel.maximumNumberOfLines = 2
        glass.contentView = content
        tray.isHidden = true
        tray.onRemove = { [weak self] hash in self?.removeDraft(hash) }
        attachButton.isBordered = false
        attachButton.image = NSImage(systemSymbolName: "plus.circle.fill", accessibilityDescription: HomeStrings.attachFiles)
        attachButton.imageScaling = .scaleProportionallyUpOrDown
        attachButton.contentTintColor = .secondaryLabelColor
        attachButton.setAccessibilityLabel(HomeStrings.attachFiles)
        attachButton.toolTip = HomeStrings.attachFiles
        attachButton.target = self
        attachButton.action = #selector(attachClicked)
        attachButton.isHidden = true
        addSubview(placeholder)
        applyFont()
    }

    @objc private func attachClicked() { onAttach() }

    /// Adds a prepared attachment to the draft (after the ones already there).
    func addDraft(_ draft: HomeDraftAttachment) {
        guard !draftAttachments.contains(where: { $0.ref.hash == draft.ref.hash }) else { return }
        draftAttachments.append(draft)
        draftChanged()
    }

    func removeDraft(_ hash: String) {
        draftAttachments.removeAll { $0.ref.hash == hash }
        draftChanged()
    }

    func clearDrafts() {
        draftAttachments = []
        draftChanged()
    }

    private func draftChanged() {
        tray.show(draftAttachments)
        tray.isHidden = draftAttachments.isEmpty
        needsLayout = true
        onHeightChange()
    }

    /// Shows (or with nil clears) the refusal notice above the text.
    func showNotice(_ text: String?) {
        guard text != notice else { return }
        notice = text
        noticeLabel.stringValue = text ?? ""
        noticeLabel.isHidden = text == nil
        noticeLabel.setAccessibilityLabel(text)
        if let text { NSAccessibility.post(element: noticeLabel, notification: .announcementRequested,
                                           userInfo: [.announcement: text]) }
        needsLayout = true
        onHeightChange()
    }

    static let noticeHeight: CGFloat = 30
    var noticeSpace: CGFloat { notice == nil ? 0 : Self.noticeHeight }
    /// Space the tray and the notice take above the text.
    var trayHeight: CGFloat { (draftAttachments.isEmpty ? 0 : HomeDraftTrayView.height) + noticeSpace }
    /// The attach button's side and the text's left edge.
    var attachSide: CGFloat { (22 * scale).rounded() }
    var textLeft: CGFloat { attachEnabled ? horizontalInset + attachSide + 6 : horizontalInset }

    private func applyFont() {
        glass.cornerRadius = height(lines: 1) / 2
        let font = NSFont.systemFont(ofSize: Self.baseFontSize * scale)
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = lineHeight
        paragraph.maximumLineHeight = lineHeight
        textView.font = font
        textView.typingAttributes = [.font: font, .paragraphStyle: paragraph, .foregroundColor: NSColor.labelColor]
        // Restyle committed text only: IME marked text keeps its own
        // attributes (the scale applies to it once it is committed).
        if let storage = textView.textStorage, storage.length > 0, !textView.hasMarkedText() {
            storage.addAttributes([.font: font, .paragraphStyle: paragraph], range: NSRange(location: 0, length: storage.length))
        }
        placeholder.font = font
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    /// Lines the draft needs at the current width (1...maxLines).
    var lines: Int {
        guard let manager = textView.textLayoutManager else { return 1 }
        manager.ensureLayout(for: manager.documentRange)
        let used = manager.usageBoundsForTextContainer.height
        let n = Int((max(used, lineHeight) / lineHeight).rounded())
        return min(Self.maxLines, max(1, n))
    }

    var preferredHeight: CGFloat { height(lines: lines) + trayHeight }

    var text: String {
        get { textView.string }
        set { textView.string = newValue; textChanged() }
    }

    private func textChanged() {
        if notice != nil, !textView.string.isEmpty { showNotice(nil) }
        placeholder.isHidden = !textView.string.isEmpty || textView.hasMarkedText()
        onHeightChange()
    }

    override func layout() {
        super.layout()
        glass.frame = bounds
        content.frame = glass.bounds
        let top = verticalInset + trayHeight
        let width = max(0, bounds.width - textLeft - horizontalInset)
        let height = max(0, bounds.height - top - verticalInset)
        noticeLabel.frame = CGRect(x: horizontalInset, y: verticalInset / 2, width: max(0, bounds.width - 2 * horizontalInset),
                                   height: Self.noticeHeight)
        tray.frame = CGRect(x: horizontalInset, y: verticalInset / 2 + noticeSpace, width: max(0, bounds.width - 2 * horizontalInset),
                            height: HomeDraftTrayView.height)
        textView.frame = CGRect(x: textLeft, y: top, width: width, height: height)
        let side = attachSide
        attachButton.frame = CGRect(x: horizontalInset - 4, y: bounds.height - verticalInset - lineHeight / 2 - side / 2,
                                    width: side, height: side)
        placeholder.frame = CGRect(x: textLeft, y: top - 1, width: width, height: lineHeight + 2)
    }
}

/// Return sends; Option- or Shift-Return adds a newline; IME marked text
/// keeps Return for its own commit.
final class HomeFieldTextView: NSTextView {
    var onSend: () -> Void = {}
    var onChange: () -> Void = {}
    /// Files and pasted pictures go to the draft attachments, not into the text.
    var onAttachmentPasteboard: (NSPasteboard) -> Bool = { _ in false }

    override func paste(_ sender: Any?) {
        if onAttachmentPasteboard(.general) { return }
        super.paste(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        if onAttachmentPasteboard(sender.draggingPasteboard) { return true }
        return super.performDragOperation(sender)
    }

    override func keyDown(with event: NSEvent) {
        if hasMarkedText() { super.keyDown(with: event); return }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 36 || event.keyCode == 76 {
            if flags.contains(.option) || flags.contains(.shift) {
                insertText("\n", replacementRange: selectedRange())
            } else {
                onSend()
            }
            return
        }
        super.keyDown(with: event)
    }

    override func didChangeText() {
        super.didChangeText()
        onChange()
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        onChange()
    }
}

/// A plain container with a top-left origin.
final class HomeFlippedView: NSView {
    override var isFlipped: Bool { true }
}
