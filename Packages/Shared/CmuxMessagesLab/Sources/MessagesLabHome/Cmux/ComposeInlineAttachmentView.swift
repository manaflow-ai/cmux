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
        removeButton.setHomeToolTip(CmuxStrings.removeAttachment)
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

    /// The attachment shown (nil once it is gone).
    var attachmentID: ID? { attachment?.attachmentID }

    /// A picture's thumbnail as shown (nil: the placeholder grey, or a file pill).
    var thumbnail: CGImage? { attachment?.isImage == true ? attachment?.thumbnail : nil }

    /// The field that holds this view.
    private var field: FieldTextView? {
        var v: NSView? = superview
        while let next = v, !(next is FieldTextView) { v = next.superview }
        return v as? FieldTextView
    }

    /// A press and release this close together (points, window coordinates) is a click, not a drag.
    static let clickSlop: CGFloat = 4
    static func isClick(from down: CGPoint, to up: CGPoint) -> Bool { hypot(up.x - down.x, up.y - down.y) <= clickSlop }

    /// A click on a picture opens it large (issue 51939: it opened nothing). The press still goes to the field
    /// first (its caret and its own drag of the attachment); a release in place over the picture opens it.
    override func mouseDown(with event: NSEvent) {
        guard attachment?.isImage == true, event.clickCount == 1 else { super.mouseDown(with: event); return }
        let down = event.locationInWindow
        super.mouseDown(with: event)
        var up = NSApp.currentEvent
        // Nothing above tracked the press (the current event is still this press): wait for its release here.
        if let e = up, e.type == .leftMouseDown, e.timestamp == event.timestamp {
            repeat { up = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) } while up.map { $0.type != .leftMouseUp } ?? false
        }
        guard let up, up.type == .leftMouseUp, Self.isClick(from: down, to: up.locationInWindow),
              bounds.contains(convert(up.locationInWindow, from: nil)) else { return }
        openPreview()
    }

    /// Opens the picture large through the field's host; false for a file pill or with no host.
    @discardableResult
    func openPreview() -> Bool {
        guard let attachment, attachment.isImage, let field else { return false }
        return field.onOpenDraftPicture(attachment.attachmentID, self)
    }

    override func mouseEntered(with event: NSEvent) { showsRemove = true }
    override func mouseExited(with event: NSEvent) { showsRemove = false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }

    /// Right-click: the picture's or file's own rows (Copy, Save As…, Open in Default App; the shared
    /// ``HomeContentMenu``) and Remove Attachment. The draft's file comes from the field that holds this view.
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let attachment else { return nil }
        let lookup = field?.draftAttachmentFile
        let id = attachment.attachmentID
        let resolve: @MainActor @Sendable () async -> URL? = { lookup?(id) }
        let menu = NSMenu()
        HomeContentMenu(attachmentRows: HomeAttachmentRows(window: window))
            .attachmentItems(name: attachment.model.fileName, resolve: resolve) {
                if let file = lookup?(id) { NSWorkspace.shared.open(file) }
            }.forEach(menu.addItem)
        menu.addItem(.separator())
        menu.addItem(MenuAction(title: CmuxStrings.removeAttachment, symbol: "xmark.circle") { [weak self] in self?.removeClicked() })
        return NSMenu.systemFree(menu)
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
        name.textColor = Fixture.composeText
        let kind = NSTextField(labelWithString: ComposeAttachmentStrip.fit(ComposeAttachmentStrip.kindText(a), ComposeAttachmentStrip.kindFont, bounds.width - 60))
        kind.font = ComposeAttachmentStrip.kindFont
        kind.textColor = Fixture.secondaryText
        name.frame = CGRect(x: 50, y: bounds.height / 2, width: bounds.width - 60, height: 15)
        kind.frame = CGRect(x: 50, y: bounds.height / 2 - 15, width: bounds.width - 60, height: 14)
        addSubview(name)
        addSubview(kind)
    }
}
