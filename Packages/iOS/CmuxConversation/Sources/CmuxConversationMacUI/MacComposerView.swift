#if os(macOS)
import AppKit
import CmuxConversationCore
import CmuxConversationGeometry
import UniformTypeIdentifiers

struct MacComposerAttachment {
    let id = UUID()
    var image: NSImage
    var data: Data
    var mimeType: String

    /// Images on a pasteboard (paste or drop). Image files keep their
    /// original bytes and type, as Messages sends them; a JPEG photo is not
    /// re-encoded as a many-times-larger PNG. Raw image data becomes PNG.
    static func images(on pasteboard: NSPasteboard) -> [MacComposerAttachment] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingContentsConformToTypes: [UTType.image.identifier]]
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL], !urls.isEmpty {
            return urls.compactMap(fromFile)
        }
        let images = (pasteboard.readObjects(forClasses: [NSImage.self]) as? [NSImage]) ?? []
        return images.compactMap(asPNG)
    }

    static func fromFile(_ url: URL) -> MacComposerAttachment? {
        guard let data = try? Data(contentsOf: url), let image = NSImage(data: data) else { return nil }
        let type = UTType(filenameExtension: url.pathExtension)
        let sendable: [UTType] = [.jpeg, .png, .gif, .heic]
        if let type, sendable.contains(where: { type.conforms(to: $0) }), let mime = type.preferredMIMEType {
            return MacComposerAttachment(image: image, data: data, mimeType: mime)
        }
        return asPNG(image)
    }

    static func asPNG(_ image: NSImage) -> MacComposerAttachment? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        return MacComposerAttachment(image: image, data: png, mimeType: "image/png")
    }

    /// Whether a paste should attach images rather than insert text. Finder
    /// puts the file name on the pasteboard beside a copied image file, so a
    /// string alone does not mean "paste text".
    static func pasteboardPrefersImages(_ pasteboard: NSPasteboard) -> Bool {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingContentsConformToTypes: [UTType.image.identifier]]
        if pasteboard.canReadObject(forClasses: [NSURL.self], options: options) { return true }
        return pasteboard.canReadObject(forClasses: [NSImage.self]) && pasteboard.string(forType: .string) == nil
    }
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
    /// While set, the caret rect reported to the input system is this screen
    /// rect; the character palette uses it to anchor, so the emoji picker
    /// points at the emoji button, as in Messages.
    var paletteAnchorScreenRect: NSRect?

    override func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        paletteAnchorScreenRect ?? super.firstRect(forCharacterRange: range, actualRange: actualRange)
    }

    // Once anything is typed or picked, the input system follows the caret again.
    override func didChangeText() {
        paletteAnchorScreenRect = nil
        super.didChangeText()
    }

    override func resignFirstResponder() -> Bool {
        paletteAnchorScreenRect = nil
        return super.resignFirstResponder()
    }

    var onSubmit: (() -> Void)?
    var onPasteImages: (([MacComposerAttachment]) -> Bool)?
    /// Consulted before any command (the mention list claims arrows/Return).
    var commandInterceptor: ((Selector) -> Bool)?
    /// Plain body attributes; formatting is layered on through the semantic keys.
    var baseTypingAttributes: [NSAttributedString.Key: Any] = [:]
    var onFormattingChanged: (() -> Void)?
    /// Draws non-semantic decorations (mention bold and colors) over the
    /// formatting each time it is re-derived, so both survive every restyle.
    var decorateStorage: ((NSTextStorage) -> Void)?
    /// Draws and loops text-effect glyphs over the text, which draws them clear.
    let effectLayer = ConversationTextEffectLayer()

    /// Cmd-B/I/U format the draft. The window offers key equivalents to the
    /// focused view before the main menu, so these win only while composing.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if window?.firstResponder === self, flags == .command, let key = event.charactersIgnoringModifiers?.lowercased() {
            switch key {
            case "b": toggle(.bold); return true
            case "i": toggle(.italic); return true
            case "u": toggle(.underline); return true
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Format > Font > Underline (NSText action).
    override func underline(_ sender: Any?) { toggle(.underline) }

    /// Font panel and Format > Font changes would bypass the run model.
    override func changeFont(_ sender: Any?) {}

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        menu.insertItem(textEffectsMenuItem(), at: 0)
        menu.insertItem(formatMenuItem(), at: 0)
        menu.insertItem(.separator(), at: 2)
        return menu
    }

    override func doCommand(by selector: Selector) {
        if commandInterceptor?(selector) == true { return }
        if selector == #selector(insertNewline(_:)) {
            let flags = NSApp.currentEvent?.modifierFlags ?? []
            if flags.contains(.shift) || flags.contains(.option) {
                insertNewlineIgnoringFieldEditor(nil)
            } else {
                onSubmit?()
            }
            return
        }
        switch selector {
        case #selector(cancelOperation(_:)):
            // Esc cancels a reply, edit or tapback; NSTextView would open
            // word completion instead, which Messages never shows.
            onCancel?()
        case #selector(insertTab(_:)):
            // Tab moves focus (sidebar, transcript, composer); Option-Tab
            // still inserts a tab character.
            window?.selectNextKeyView(self)
        case #selector(insertBacktab(_:)):
            window?.selectPreviousKeyView(self)
        default:
            super.doCommand(by: selector)
        }
    }

    var onCancel: (() -> Void)?

    override func paste(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        if MacComposerAttachment.pasteboardPrefersImages(pasteboard) {
            let images = MacComposerAttachment.images(on: pasteboard)
            if !images.isEmpty, onPasteImages?(images) == true { return }
        }
        // Rich text from elsewhere would bring foreign fonts and colors.
        pasteAsPlainText(sender)
    }

    override func layout() {
        super.layout()
        refreshEffects()
    }
}

/// macOS Messages composer: a round "+" apps button and a rounded field with
/// the "iMessage" placeholder and an emoji button. The field grows line by
/// line to a cap, then scrolls. Images can be pasted or dropped onto it.
final class MacComposerView: MacFlippedView, NSTextViewDelegate {
    weak var delegate: (any MacComposerViewDelegate)?
    let appsButton = NSButton()
    /// The glass pill (NSGlassEffectView on macOS 26).
    let field: NSView = {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = 15.75
            return glass
        }
        let view = MacFlippedView()
        view.layer?.cornerRadius = 15.75
        return view
    }()
    let fieldContent = MacFlippedView()
    let audioButton = MacGlyphView()
    private let emojiGlyph = MacGlyphView()
    let scrollView = NSScrollView()
    let textView = MacComposerTextView()
    let placeholder = makeMacLabel()
    let emojiButton = NSButton()
    private let attachmentStrip = MacFlippedView()
    private(set) var attachments: [MacComposerAttachment] = []
    /// Mention ranges, the gray candidate and the suggestion list for the draft.
    private(set) lazy var mentionController = MacComposerMentionController(textView: textView)
    /// Pending rich link card for a URL that opens or ends the draft.
    let linkPreview = MacComposerLinkPreview()
    var placeholderText = String(localized: "conversation.composer.placeholder", defaultValue: "iMessage", bundle: .module) {
        didSet { updatePlaceholder() }
    }
    var isReplyMode = false { didSet { updatePlaceholder() } }
    var isEditMode = false { didSet { updatePlaceholder() } }
    var maximumFieldHeight: CGFloat = 220
    /// Measured: the pill is 32 pt tall and sits 11 pt above the window bottom.
    private(set) var fieldHeight: CGFloat = 32
    private let lineHeight = MacConversationTheme.lineHeight
    private let minFieldHeight: CGFloat = 32
    private let attachmentHeight: CGFloat = 80

    /// Just the pill: the accessory adds its own bottom padding, and layout
    /// solves the remaining window-relative gap. A taller accessory would push
    /// its edge effect up over the newest message.
    var preferredHeight: CGFloat { fieldHeight + 2 }

    var text: String {
        get { textView.string }
        set {
            textView.string = newValue
            mentionController.reset()
            textDidChange()
        }
    }

    var hasContent: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        // Palette (non-template) symbols keep full label contrast in inactive
        // windows, as Messages' composer glyphs do.
        appsButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: String(localized: "conversation.composer.plus", defaultValue: "Apps", bundle: .module))?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .medium).applying(.init(paletteColors: [.labelColor])))
        if #available(macOS 26.0, *) {
            appsButton.bezelStyle = .glass
            appsButton.controlSize = .large
            appsButton.borderShape = .circle
        } else {
            appsButton.isBordered = false
        }
        appsButton.contentTintColor = .labelColor
        appsButton.target = self
        appsButton.action = #selector(appsTapped)
        appsButton.setAccessibilityIdentifier("conversation.composer.plus")
        addSubview(appsButton)

        addSubview(field)
        if #available(macOS 26.0, *), let glass = field as? NSGlassEffectView {
            glass.contentView = fieldContent
        } else {
            field.addSubview(fieldContent)
        }
        fieldContent.addSubview(attachmentStrip)
        fieldContent.addSubview(linkPreview.container)
        linkPreview.onChange = { [weak self] in
            self?.needsLayout = true
            self?.updateHeight()
        }

        // Rich so the storage keeps per-run fonts; paste stays plain.
        textView.isRichText = true
        textView.importsGraphics = false
        textView.usesFontPanel = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = MacConversationTheme.bodyFont
        textView.baseTypingAttributes = [
            .font: MacConversationTheme.bodyFont,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: MacConversationTheme.bodyParagraph,
        ]
        textView.typingAttributes = textView.baseTypingAttributes
        textView.wantsLayer = true
        textView.layer?.addSublayer(textView.effectLayer)
        textView.onFormattingChanged = { [weak self] in self?.textDidChange() }
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
            images.forEach { self.addAttachment($0) }
            return true
        }
        textView.registerForDraggedTypes([.fileURL, .png, .tiff])
        textView.setAccessibilityIdentifier("conversation.composer.text")
        textView.commandInterceptor = { [weak self] selector in self?.mentionController.handle(selector) ?? false }
        _ = mentionController
        scrollView.documentView = textView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.verticalScrollElasticity = .none
        fieldContent.addSubview(scrollView)

        placeholder.font = MacConversationTheme.bodyFont
        placeholder.textColor = .tertiaryLabelColor
        fieldContent.addSubview(placeholder)

        // Glass buttons re-template their image (the inverse face lost its fill),
        // so the glyph rides in an image view above the glass.
        emojiButton.setAccessibilityLabel(String(localized: "conversation.composer.emoji", defaultValue: "Emoji", bundle: .module))
        if #available(macOS 26.0, *) {
            emojiButton.bezelStyle = .glass
            emojiButton.controlSize = .large
            emojiButton.borderShape = .circle
        } else {
            emojiButton.isBordered = false
        }
        emojiButton.contentTintColor = .labelColor
        emojiButton.target = self
        emojiButton.action = #selector(emojiTapped)
        addSubview(emojiButton)
        addSubview(emojiGlyph)

        audioButton.setAccessibilityLabel(String(localized: "conversation.composer.audio", defaultValue: "Record audio", bundle: .module))
        fieldContent.addSubview(audioButton)

        registerForDraggedTypes([.fileURL, .png, .tiff])
        updatePlaceholder()
        updateColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Messages' five-bar audio glyph (no SF Symbol matches): 1.75 pt bars,
    /// 3.6 pt apart, heights 4/7/14/7/4 pt, secondary label color.
    private static func waveformGlyph(color: NSColor) -> NSImage {
        let image = NSImage(size: NSSize(width: 16.5, height: 14), flipped: true) { rect in
            color.setFill()
            for (index, height) in [4.0, 7.0, 14.0, 7.0, 4.0].enumerated() {
                let x = 0.0 + Double(index) * 3.6
                let bar = NSRect(x: x, y: (rect.height - height) / 2, width: 1.75, height: height)
                NSBezierPath(roundedRect: bar, xRadius: 0.875, yRadius: 0.875).fill()
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    /// Messages' grinning emoji glyph: a solid 15 pt face with knocked-out eyes
    /// and an open grin whose upper teeth stay solid.
    private static func emojiGlyph(color: NSColor) -> NSImage {
        let image = NSImage(size: NSSize(width: 15, height: 15), flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.setFillColor(color.cgColor)
            context.fillEllipse(in: rect)
            context.setBlendMode(.clear)
            context.fillEllipse(in: CGRect(x: 4.0, y: 3.3, width: 2.0, height: 3.1))
            context.fillEllipse(in: CGRect(x: 9.0, y: 3.3, width: 2.0, height: 3.1))
            let mouth = CGMutablePath()
            mouth.move(to: CGPoint(x: 3.0, y: 7.7))
            mouth.addLine(to: CGPoint(x: 12.0, y: 7.7))
            mouth.addCurve(to: CGPoint(x: 3.0, y: 7.7), control1: CGPoint(x: 11.8, y: 13.9), control2: CGPoint(x: 3.2, y: 13.9))
            context.addPath(mouth)
            context.fillPath()
            context.setBlendMode(.normal)
            context.addPath(mouth)
            context.clip()
            context.fill(CGRect(x: 2.5, y: 7.7, width: 10, height: 2.0))
            return true
        }
        image.isTemplate = false
        return image
    }

    private func updateGlyphs() {
        // Fixed resolved colors: the glass container otherwise dims dynamic
        // label colors in inactive windows, which Messages does not.
        let dark = effectiveAppearance.isDarkMac
        emojiGlyph.image = Self.emojiGlyph(color: dark ? NSColor(white: 0.96, alpha: 1) : NSColor(white: 0.1, alpha: 1))
        audioButton.image = Self.waveformGlyph(color: dark ? NSColor(white: 0.53, alpha: 1) : NSColor(white: 0.45, alpha: 1))
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        updateGlyphs()
        // Transparent: the split view accessory supplies the scroll edge effect behind it.
        layer?.backgroundColor = nil
        if #unavailable(macOS 26.0) {
            field.layer?.backgroundColor = resolved(.controlBackgroundColor, in: self)
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        // Frame-based layout: a new size (the accessory grew for a pasted
        // block) must re-place the pill even when nothing else marks layout.
        if changed { needsLayout = true }
    }

    override func layout() {
        super.layout()
        // Measured against macOS 26 Messages (window coordinates): 30 pt glass
        // circles 12.5 pt from the window's trailing edge, 9.5 pt between circle
        // and pill, pill bottom 11 pt above the window bottom. The split view
        // accessory adds its own padding, so solve for the window-relative gap.
        let circle: CGFloat = 30
        var side: CGFloat = 11.5
        var bottomInset: CGFloat = 11
        if let window, let contentBounds = window.contentView?.bounds {
            let inWindow = convert(bounds, to: nil)
            side = max(0, 11.5 - (contentBounds.width - inWindow.maxX))
            bottomInset = max(0, 11 - inWindow.minY)
        }
        let fieldBottom = bounds.height - bottomInset
        appsButton.frame = CGRect(x: max(0, side - 1.5), y: fieldBottom - (minFieldHeight + circle) / 2, width: circle, height: circle)
        emojiButton.frame = CGRect(x: bounds.width - side - circle, y: fieldBottom - (minFieldHeight + circle) / 2, width: circle, height: circle)
        emojiGlyph.frame = emojiButton.frame
        let fieldX = appsButton.frame.maxX + 9.5
        field.frame = CGRect(x: fieldX, y: fieldBottom - fieldHeight, width: emojiButton.frame.minX - 9.5 - fieldX, height: fieldHeight)
        fieldContent.frame = field.bounds
        if #available(macOS 26.0, *), let glass = field as? NSGlassEffectView {
            glass.cornerRadius = min(fieldHeight, minFieldHeight) / 2
        }
        let content = fieldContent.bounds
        var textTop: CGFloat = 0
        attachmentStrip.isHidden = attachments.isEmpty
        if !attachments.isEmpty {
            attachmentStrip.frame = CGRect(x: 8, y: 6, width: content.width - 16, height: attachmentHeight)
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
        if linkPreview.preview != nil {
            linkPreview.layout(contentWidth: content.width)
            linkPreview.container.frame.origin.y = textTop
            textTop += linkPreview.container.frame.height
        }
        let textInset: CGFloat = 11
        let verticalInset = (minFieldHeight - lineHeight) / 2
        scrollView.frame = CGRect(x: textInset, y: textTop + verticalInset, width: content.width - textInset - 34, height: content.height - textTop - verticalInset)
        textView.minSize = CGSize(width: 0, height: lineHeight)
        textView.maxSize = CGSize(width: scrollView.frame.width, height: .greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.textContainer?.containerSize = CGSize(width: scrollView.frame.width, height: .greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.frame.size.width = scrollView.contentSize.width
        placeholder.frame = CGRect(x: textInset, y: textTop + verticalInset, width: content.width - textInset - 40, height: lineHeight)
        audioButton.frame = CGRect(x: content.width - 29, y: content.height - minFieldHeight + 5, width: 22, height: minFieldHeight - 10)
        audioButton.isHidden = hasContent
    }

    func textDidChange(_ notification: Notification) {
        textView.restyle()
        textDidChange()
    }

    /// Formatting of the draft (UTF-16 offsets into `text`).
    var textRuns: [ConversationTextRun] { textView.textRuns }

    /// Loads a draft with formatting (editing a sent message).
    func setText(_ text: String, runs: [ConversationTextRun]) {
        textView.setText(text, runs: runs)
        textDidChange()
    }

    private func textDidChange() {
        mentionController.textDidChange()
        updatePlaceholder()
        needsLayout = true
        updateHeight()
        linkPreview.textChanged(text)
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
        natural += linkPreview.height(forContentWidth: fieldContent.bounds.width > 0 ? fieldContent.bounds.width : bounds.width - 100)
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
        mentionController.reset()
        textView.resetFormatting()
        linkPreview.reset()
        attachments = []
        attachmentStrip.subviews.forEach { $0.removeFromSuperview() }
        updatePlaceholder()
        updateHeight()
        delegate?.composerDidChangeText(self)
    }

    func addAttachment(_ attachment: MacComposerAttachment) {
        let image = attachment.image
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
        if let window {
            // Anchor the palette's arrow at the emoji button's top center.
            let rect = emojiButton.convert(emojiButton.bounds, to: nil)
            textView.paletteAnchorScreenRect = window.convertToScreen(rect)
        }
        NSApp.orderFrontCharacterPalette(nil)
    }

    // MARK: Drag and drop

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        canAcceptImages(sender) ? .copy : []
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let images = MacComposerAttachment.images(on: sender.draggingPasteboard)
        images.forEach { addAttachment($0) }
        return !images.isEmpty
    }

    /// Checks types only; decoding every dragged file on each hover is slow.
    private func canAcceptImages(_ sender: any NSDraggingInfo) -> Bool {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingContentsConformToTypes: [UTType.image.identifier]]
        return sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: options)
            || sender.draggingPasteboard.canReadObject(forClasses: [NSImage.self])
    }
}

/// Draws a fixed-color glyph image centered, through the layer, so inactive
/// window dimming (applied to NSImageView/NSButton content) does not touch it.
final class MacGlyphView: MacFlippedView {
    var image: NSImage? { didSet { needsLayout = true } }

    override func layout() {
        super.layout()
        guard let image, let layer else { layer?.contents = nil; return }
        let scale = window?.backingScaleFactor ?? 2
        layer.contentsScale = scale
        layer.contents = image.cgImage(forProposedRect: nil, context: nil, hints: [.ctm: AffineTransform(scale: scale)])
        layer.contentsGravity = .center
    }
}
#endif
