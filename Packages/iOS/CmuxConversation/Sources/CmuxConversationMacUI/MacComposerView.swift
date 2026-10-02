#if os(macOS)
import AppKit
import UniformTypeIdentifiers

struct MacComposerAttachment {
    let id = UUID()
    var image: NSImage
    var data: Data
    var mimeType: String
}

@MainActor
protocol MacComposerViewDelegate: AnyObject {
    func composerDidChangeText(_ composer: MacComposerView)
    func composerDidChangeHeight(_ composer: MacComposerView)
    func composerDidSubmit(_ composer: MacComposerView)
    func composerDidTapApps(_ composer: MacComposerView)
}

/// Text view that sends on Return and inserts a newline on Shift/Option-Return.
final class MacComposerTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var onPasteImages: (([NSImage]) -> Bool)?

    override func doCommand(by selector: Selector) {
        if selector == #selector(insertNewline(_:)) {
            let flags = NSApp.currentEvent?.modifierFlags ?? []
            if flags.contains(.shift) || flags.contains(.option) {
                insertNewlineIgnoringFieldEditor(nil)
            } else {
                onSubmit?()
            }
            return
        }
        super.doCommand(by: selector)
    }

    override func paste(_ sender: Any?) {
        if let images = NSPasteboard.general.readObjects(forClasses: [NSImage.self]) as? [NSImage], !images.isEmpty,
           NSPasteboard.general.string(forType: .string) == nil, onPasteImages?(images) == true {
            return
        }
        super.paste(sender)
    }
}

/// macOS Messages composer: a round "+" apps button and a rounded field with
/// the "iMessage" placeholder and an emoji button. The field grows line by
/// line to a cap, then scrolls. Images can be pasted or dropped onto it.
final class MacComposerView: MacFlippedView, NSTextViewDelegate {
    weak var delegate: (any MacComposerViewDelegate)?
    let appsButton = NSButton()
    let field = MacFlippedView()
    let scrollView = NSScrollView()
    let textView = MacComposerTextView()
    private let placeholder = makeMacLabel()
    let emojiButton = NSButton()
    private let attachmentStrip = MacFlippedView()
    private(set) var attachments: [MacComposerAttachment] = []
    var placeholderText = String(localized: "conversation.composer.placeholder", defaultValue: "iMessage", bundle: .module) {
        didSet { updatePlaceholder() }
    }
    var isReplyMode = false { didSet { updatePlaceholder() } }
    var isEditMode = false { didSet { updatePlaceholder() } }
    var maximumFieldHeight: CGFloat = 220
    private(set) var fieldHeight: CGFloat = 28
    private let lineHeight = MacConversationTheme.lineHeight
    private let minFieldHeight: CGFloat = 28
    private let attachmentHeight: CGFloat = 80

    var preferredHeight: CGFloat { fieldHeight + 20 }

    var text: String {
        get { textView.string }
        set {
            textView.string = newValue
            textDidChange()
        }
    }

    var hasContent: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        appsButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: String(localized: "conversation.composer.plus", defaultValue: "Apps", bundle: .module))
        appsButton.symbolConfiguration = .init(pointSize: 13, weight: .semibold)
        appsButton.isBordered = false
        appsButton.wantsLayer = true
        appsButton.layer?.cornerRadius = 14
        appsButton.contentTintColor = .secondaryLabelColor
        appsButton.target = self
        appsButton.action = #selector(appsTapped)
        appsButton.setAccessibilityIdentifier("conversation.composer.plus")
        addSubview(appsButton)

        field.layer?.cornerRadius = 14
        field.layer?.borderWidth = 1
        addSubview(field)
        field.addSubview(attachmentStrip)

        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = MacConversationTheme.bodyFont
        textView.typingAttributes = [
            .font: MacConversationTheme.bodyFont,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: MacConversationTheme.bodyParagraph,
        ]
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.isAutomaticQuoteSubstitutionEnabled = true
        textView.delegate = self
        textView.onSubmit = { [weak self] in
            guard let self, self.hasContent else { return }
            self.delegate?.composerDidSubmit(self)
        }
        textView.onPasteImages = { [weak self] images in
            guard let self else { return false }
            images.forEach { self.addImage($0) }
            return true
        }
        textView.registerForDraggedTypes([.fileURL, .png, .tiff])
        textView.setAccessibilityIdentifier("conversation.composer.text")
        scrollView.documentView = textView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.verticalScrollElasticity = .none
        field.addSubview(scrollView)

        placeholder.font = MacConversationTheme.bodyFont
        placeholder.textColor = .placeholderTextColor
        field.addSubview(placeholder)

        emojiButton.image = NSImage(systemSymbolName: "face.smiling", accessibilityDescription: String(localized: "conversation.composer.emoji", defaultValue: "Emoji", bundle: .module))
        emojiButton.symbolConfiguration = .init(pointSize: 14, weight: .regular)
        emojiButton.isBordered = false
        emojiButton.contentTintColor = .secondaryLabelColor
        emojiButton.target = self
        emojiButton.action = #selector(emojiTapped)
        field.addSubview(emojiButton)

        registerForDraggedTypes([.fileURL, .png, .tiff])
        updatePlaceholder()
        updateColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        layer?.backgroundColor = resolved(MacConversationTheme.background, in: self)
        appsButton.layer?.backgroundColor = resolved(.quaternaryLabelColor, in: self)
        field.layer?.borderColor = resolved(.separatorColor, in: self)
        field.layer?.backgroundColor = resolved(.textBackgroundColor, in: self)
    }

    override func layout() {
        super.layout()
        let side: CGFloat = 12
        appsButton.frame = CGRect(x: side, y: bounds.height - 10 - 28, width: 28, height: 28)
        let fieldX = appsButton.frame.maxX + 8
        field.frame = CGRect(x: fieldX, y: bounds.height - 10 - fieldHeight, width: bounds.width - fieldX - side, height: fieldHeight)
        var textTop: CGFloat = 0
        attachmentStrip.isHidden = attachments.isEmpty
        if !attachments.isEmpty {
            attachmentStrip.frame = CGRect(x: 8, y: 6, width: field.bounds.width - 16, height: attachmentHeight)
            textTop = attachmentHeight + 10
            var x: CGFloat = 0
            for (index, view) in attachmentStrip.subviews.enumerated() where index < attachments.count {
                let image = attachments[index].image
                let w = min(160, max(50, attachmentHeight * image.size.width / max(1, image.size.height)))
                view.frame = CGRect(x: x, y: 0, width: w, height: attachmentHeight)
                view.subviews.last?.frame = CGRect(x: w - 20, y: 3, width: 17, height: 17)
                x += w + 6
            }
        }
        scrollView.frame = CGRect(x: 10, y: textTop + 5.5, width: field.bounds.width - 10 - 30, height: field.bounds.height - textTop - 5.5)
        textView.minSize = CGSize(width: 0, height: lineHeight)
        textView.maxSize = CGSize(width: scrollView.frame.width, height: .greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.textContainer?.containerSize = CGSize(width: scrollView.frame.width, height: .greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.frame.size.width = scrollView.contentSize.width
        placeholder.frame = CGRect(x: 10, y: textTop + 5.5, width: field.bounds.width - 50, height: lineHeight)
        emojiButton.frame = CGRect(x: field.bounds.width - 28, y: field.bounds.height - 24, width: 22, height: 20)
    }

    func textDidChange(_ notification: Notification) {
        textDidChange()
    }

    private func textDidChange() {
        updatePlaceholder()
        updateHeight()
        delegate?.composerDidChangeText(self)
    }

    private func updatePlaceholder() {
        placeholder.stringValue = isEditMode
            ? ""
            : !attachments.isEmpty
                ? String(localized: "conversation.composer.addComment", defaultValue: "Add comment or Send", bundle: .module)
                : (isReplyMode ? String(localized: "conversation.composer.reply", defaultValue: "Reply", bundle: .module) : placeholderText)
        placeholder.isHidden = !textView.string.isEmpty
    }

    /// Grows by whole lines with no animation, up to `maximumFieldHeight`.
    func updateHeight() {
        guard let container = textView.textContainer, let manager = textView.layoutManager else { return }
        manager.ensureLayout(for: container)
        let used = manager.usedRect(for: container).height
        let lines = max(1, round(used / lineHeight))
        var natural = minFieldHeight + (lines - 1) * lineHeight
        if !attachments.isEmpty { natural += attachmentHeight + 10 }
        let height = min(natural, maximumFieldHeight)
        guard height != fieldHeight else { return }
        fieldHeight = height
        needsLayout = true
        layoutSubtreeIfNeeded()
        delegate?.composerDidChangeHeight(self)
        textView.scrollRangeToVisible(textView.selectedRange())
    }

    func clearAfterSend() {
        textView.string = ""
        attachments = []
        attachmentStrip.subviews.forEach { $0.removeFromSuperview() }
        updatePlaceholder()
        updateHeight()
        delegate?.composerDidChangeText(self)
    }

    func addImage(_ image: NSImage) {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        let attachment = MacComposerAttachment(image: image, data: png, mimeType: "image/png")
        attachments.append(attachment)
        let container = MacFlippedView()
        let imageView = NSImageView(image: image)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 8
        imageView.layer?.masksToBounds = true
        imageView.autoresizingMask = [.width, .height]
        imageView.frame = container.bounds
        container.addSubview(imageView)
        let remove = NSButton(image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: String(localized: "conversation.composer.removeAttachment", defaultValue: "Remove attachment", bundle: .module))!, target: self, action: #selector(removeAttachment(_:)))
        remove.isBordered = false
        remove.contentTintColor = .white
        remove.tag = attachments.count - 1
        container.addSubview(remove)
        attachmentStrip.addSubview(container)
        updatePlaceholder()
        updateHeight()
        needsLayout = true
        delegate?.composerDidChangeText(self)
    }

    @objc private func removeAttachment(_ sender: NSButton) {
        guard sender.tag < attachments.count else { return }
        attachments.remove(at: sender.tag)
        attachmentStrip.subviews[sender.tag].removeFromSuperview()
        for (index, view) in attachmentStrip.subviews.enumerated() { (view.subviews.last as? NSButton)?.tag = index }
        updatePlaceholder()
        updateHeight()
        needsLayout = true
    }

    @objc private func appsTapped() {
        delegate?.composerDidTapApps(self)
    }

    @objc private func emojiTapped() {
        window?.makeFirstResponder(textView)
        NSApp.orderFrontCharacterPalette(nil)
    }

    // MARK: Drag and drop

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        imageItems(sender).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let images = imageItems(sender)
        images.forEach { addImage($0) }
        return !images.isEmpty
    }

    private func imageItems(_ sender: any NSDraggingInfo) -> [NSImage] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingContentsConformToTypes: [UTType.image.identifier]]
        if let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL], !urls.isEmpty {
            return urls.compactMap { NSImage(contentsOf: $0) }
        }
        return (sender.draggingPasteboard.readObjects(forClasses: [NSImage.self]) as? [NSImage]) ?? []
    }
}
#endif
