// cmux: one attachment in the message box's text (Draft+InlineMarks.swift).
// Not a vendored file.
import AppKit
import UniformTypeIdentifiers

/// An inline attachment as the field shows it: an image's thumbnail with
/// rounded corners, or a file's pill (icon, name, kind and size); a remove
/// button shows on hover.
final class ComposeInlineAttachmentView: NSView {
    private weak var attachment: ComposeInlineAttachment?
    let removeButton = NSButton()
    private var tracking: NSTrackingArea?

    init(_ attachment: ComposeInlineAttachment) {
        self.attachment = attachment
        super.init(frame: CGRect(origin: .zero, size: attachment.pictureSize))
        wantsLayer = true
        layer?.cornerRadius = ComposeInlineAttachment.corner
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.contentsGravity = .resizeAspectFill
        layer?.backgroundColor = (Fixture.isLight ? Fixture.chipFill : NSColor(white: 1, alpha: 0.08)).cgColor
        if attachment.isImage {
            show(attachment.thumbnail)
        } else {
            addFileLabels(attachment.model)
        }
        removeButton.isBordered = false
        removeButton.bezelStyle = .regularSquare
        removeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: CmuxStrings.removeAttachment)
        removeButton.contentTintColor = NSColor(white: 1, alpha: 0.95)
        removeButton.imageScaling = .scaleProportionallyUpOrDown
        removeButton.setAccessibilityLabel(CmuxStrings.removeAttachment)
        removeButton.toolTip = CmuxStrings.removeAttachment
        removeButton.target = self
        removeButton.action = #selector(removeClicked)
        removeButton.alphaValue = 0
        addSubview(removeButton)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(attachment.model.fileName)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        let s = ComposeAttachmentStrip.removeSize
        removeButton.frame = CGRect(x: bounds.width - s - 4, y: isFlipped ? 4 : bounds.height - s - 4, width: s, height: s)
    }

    /// The thumbnail arrived (nil: the placeholder grey stays).
    func show(_ image: CGImage?) {
        guard let image else { return }
        layer?.contents = image
    }

    /// Shows the remove button (hover in, tests).
    var showsRemove: Bool {
        get { removeButton.alphaValue > 0 }
        set { removeButton.alphaValue = newValue ? 1 : 0 }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) { showsRemove = true }
    override func mouseExited(with event: NSEvent) { showsRemove = false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }

    /// Right-click: the picture's or file's own rows (Copy, Save As…, Open in Default App; the shared
    /// ``HomeContentMenu``) and Remove Attachment. The draft's file comes from the field that holds this view.
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let attachment else { return nil }
        var field: NSView? = superview
        while let v = field, !(v is FieldTextView) { field = v.superview }
        let lookup = (field as? FieldTextView)?.draftAttachmentFile
        let id = attachment.attachmentID
        let resolve: @MainActor @Sendable () async -> URL? = { lookup?(id) }
        let menu = NSMenu()
        HomeContentMenu(attachmentRows: HomeAttachmentRows(window: window))
            .attachmentItems(name: attachment.model.fileName, resolve: resolve) {
                if let file = lookup?(id) { NSWorkspace.shared.open(file) }
            }.forEach(menu.addItem)
        menu.addItem(.separator())
        menu.addItem(MenuAction(title: CmuxStrings.removeAttachment, symbol: "xmark.circle") { [weak self] in self?.removeClicked() })
        return menu
    }

    @objc func removeClicked() {
        guard let attachment else { return }
        attachment.onRemove(attachment.attachmentID)
    }

    /// One type icon per mime type for the life of the process: each file pill asked the workspace
    /// again on the main thread (a Launch Services lookup) while the field laid out its text.
    private static var icons: [String: NSImage] = [:]
    static func icon(forMimeType mime: String) -> NSImage {
        if let cached = icons[mime] { return cached }
        let image = NSWorkspace.shared.icon(for: UTType(mimeType: mime) ?? .data)
        if icons.count < 64 { icons[mime] = image }
        return image
    }

    private func addFileLabels(_ a: Attachment) {
        let icon = NSImageView(image: Self.icon(forMimeType: a.mimeType))
        icon.frame = CGRect(x: 10, y: (bounds.height - 32) / 2, width: 32, height: 32)
        addSubview(icon)
        let name = NSTextField(labelWithString: ComposeAttachmentStrip.fit(a.fileName, ComposeAttachmentStrip.nameFont, bounds.width - 60))
        name.font = ComposeAttachmentStrip.nameFont
        name.textColor = Fixture.incomingText
        let kind = NSTextField(labelWithString: ComposeAttachmentStrip.fit(ComposeAttachmentStrip.kindText(a), ComposeAttachmentStrip.kindFont, bounds.width - 60))
        kind.font = ComposeAttachmentStrip.kindFont
        kind.textColor = Fixture.secondaryText
        name.frame = CGRect(x: 50, y: bounds.height / 2, width: bounds.width - 60, height: 15)
        kind.frame = CGRect(x: 50, y: bounds.height / 2 - 15, width: bounds.width - 60, height: 14)
        addSubview(name)
        addSubview(kind)
    }
}
