// cmux: one attachment in the message box's text (Draft+InlineMarks.swift). Not a vendored file.
import AppKit
import UniformTypeIdentifiers

/// One attachment in the field's text: an image's thumbnail or a file's pill,
/// drawn by `ComposeInlineAttachmentView`. When the field does not place that view, the
/// attachment draws the same picture itself (`image(for:...)`): AppKit otherwise draws an
/// attachment with no contents as a blank document page (a screenshot pasted in the Chief's box
/// showed only that page, 2026-10-20).
final class ComposeInlineAttachment: NSTextAttachment {
    let attachmentID: ID
    private(set) var model: Attachment
    /// The remove button's action (the field deletes the mark).
    var onRemove: (ID) -> Void = { _ in }
    /// The thumbnail, once decoded (nil: the placeholder grey).
    private(set) var thumbnail: CGImage?
    private weak var shownView: ComposeInlineAttachmentView?
    /// The text container that last drew this attachment itself, redrawn when the thumbnail arrives.
    private weak var drawnIn: NSTextContainer?
    /// The picture's (or file pill's) size; the attachment's box is its whole line (`attachmentBounds`).
    let pictureSize: CGSize

    init(_ a: Attachment, scale: CGFloat) {
        attachmentID = a.id
        model = a
        // A file type with the view provider registered for it: TextKit 2 places an attachment's
        // view only for a provider class registered for its type (`viewProvider(for:...)` alone was
        // never asked, and the field drew the attachment's image with no remove button).
        _ = Self.registerViewProvider
        pictureSize = Self.size(of: a, scale: scale)
        super.init(data: nil, ofType: Self.fileType)
        bounds = CGRect(x: 0, y: Self.baselineOffset, width: pictureSize.width, height: pictureSize.height + Self.gapBelow)
        allowsTextAttachmentView = true
        loadThumbnail(scale: scale)
    }

    required init?(coder: NSCoder) { nil }

    var isImage: Bool { ComposeAttachmentStrip.isImage(model) }

    /// The attachment's box below the baseline.
    static let baselineOffset: CGFloat = -4
    /// The space between a picture and the text line under it (Messages, Austin's capture 2026-10-20).
    static let gapBelow: CGFloat = 6
    /// Messages' picture in the message box: 176 pt wide for a 1412 x 1106 px screenshot at 2x, so
    /// 176 x 138 pt (Lawrence's capture 2026-10-20, cmux-prompts/refs/composer-images/1.png: 352 px
    /// of the 2x capture), so aspect-fit in 176 x 176 pt; a smaller picture keeps its size.
    static let pictureMaxWidth: CGFloat = 176
    static let pictureMaxHeight: CGFloat = 176
    /// The picture's corner radius in the box (the same capture: about 24 px at 2x).
    static let corner: CGFloat = 12

    /// Images: aspect-fit in `pictureMaxWidth` x `pictureMaxHeight`; files: the 200 x 52 pt pill.
    static func size(of a: Attachment, scale: CGFloat) -> CGSize {
        guard ComposeAttachmentStrip.isImage(a) else {
            return CGSize(width: ComposeAttachmentStrip.fileWidth, height: ComposeAttachmentStrip.fileHeight)
        }
        let s = max(1, scale)
        let w = CGFloat(a.width ?? 1) / s, h = CGFloat(a.height ?? 1) / s
        let k = min(1, pictureMaxWidth / w, pictureMaxHeight / h)
        return CGSize(width: max(8, (w * k).rounded()), height: max(8, (h * k).rounded()))
    }

    /// A newer copy of the same attachment (its picture arrived).
    func update(_ a: Attachment, scale: CGFloat) {
        guard a != model else { return }
        let hadAsset = model.asset
        model = a
        if a.asset != hadAsset { thumbnail = nil; loadThumbnail(scale: scale) }
    }

    private func loadThumbnail(scale: CGFloat) {
        guard isImage, let asset = model.asset else { return }
        let px = thumbnailPixels(scale)
        // task-owner: one decode per attachment, off the main actor; ends with the image. The
        // thumbnail, the view and the field's layout change on the main actor (TextKit 2 lays out there).
        Task { @MainActor [weak self] in
            let image = await Task.detached(priority: .userInitiated) {
                ComposeAttachmentStrip.thumbnail(asset, maxPixels: px)
            }.value
            guard let self, self.model.asset == asset else { return }
            self.thumbnailArrived(image)
        }
    }

    /// The decoded thumbnail is here (main actor): the view or the field shows it.
    func thumbnailArrived(_ image: CGImage?) {
        thumbnail = image
        shownView?.show(image)
        redrawField()
    }

    /// The field draws the attachment again (the thumbnail arrived after it drew the placeholder):
    /// only its rect and no layout, with the other arrivals of this turn (`ComposeInlineRedraw`).
    private func redrawField() {
        guard let tv = drawnIn?.textView else { return }
        ComposeInlineRedraw.of(tv).arrived(self)
    }

    // MARK: Its own line, as in Messages

    // A picture in the message box is a block, as in Messages: it takes its whole line, so text
    // before it ends the line above and text after it starts the line below. Its box is the line's
    // width; the picture draws at the box's left (Austin 2026-10-20: the text sat beside the picture).

    override func attachmentBounds(for attributes: [NSAttributedString.Key: Any], location: any NSTextLocation, textContainer: NSTextContainer?,
                                   proposedLineFragment: CGRect, position: CGPoint) -> CGRect {
        lineBox(proposedLineFragment.width)
    }

    override func attachmentBounds(for textContainer: NSTextContainer?, proposedLineFragment lineFrag: NSRect, glyphPosition position: NSPoint,
                                   characterIndex charIndex: Int) -> NSRect {
        lineBox(lineFrag.width)
    }

    private func lineBox(_ lineWidth: CGFloat) -> CGRect {
        CGRect(x: 0, y: bounds.minY, width: max(bounds.width, lineWidth), height: bounds.height)
    }

    // MARK: Drawn by the attachment (the field placed no view)

    override func image(for imageBounds: CGRect, attributes: [NSAttributedString.Key: Any], location: any NSTextLocation,
                        textContainer: NSTextContainer?) -> NSImage? {
        drawnIn = textContainer
        return drawnImage(imageBounds.size)
    }

    override func image(forBounds imageBounds: NSRect, textContainer: NSTextContainer?, characterIndex charIndex: Int) -> NSImage? {
        drawnIn = textContainer
        return drawnImage(imageBounds.size)
    }

    /// What the view shows, as an image: the thumbnail aspect-filled in a rounded box (the box's
    /// fill until it decodes), or the file's pill with its icon, name and kind.
    func drawnImage(_ size: CGSize) -> NSImage {
        let fill = Fixture.isLight ? Fixture.chipFill : NSColor(white: 1, alpha: 0.08)
        let corner = Self.corner
        let labels = isImage ? nil : FileLabels(model, width: pictureSize.width - 60)
        // The thumbnail is read when the image draws, not when it is made: the field may keep this
        // image from before the thumbnail decoded.
        let picture = pictureSize
        let drawn = NSImage(size: size, flipped: false) { [weak self] box in
            // The picture at the box's top left; the rest of its line and the gap below stay clear.
            let r = CGRect(x: 0, y: box.maxY - min(picture.height, box.height),
                           width: min(picture.width, box.width), height: min(picture.height, box.height))
            let image = self?.isImage == true ? self?.thumbnail : nil
            NSBezierPath(roundedRect: r, xRadius: corner, yRadius: corner).addClip()
            fill.setFill()
            r.fill()
            if let image, let ctx = NSGraphicsContext.current?.cgContext {
                ctx.interpolationQuality = .high
                ctx.draw(image, in: Self.aspectFill(CGSize(width: image.width, height: image.height), in: r))
            }
            labels?.draw(in: r)
            return true
        }
        drawn.cacheMode = .never
        return drawn
    }

    /// IMAGE's rect scaled to cover BOX, centred (the view's `resizeAspectFill`).
    static func aspectFill(_ image: CGSize, in box: CGRect) -> CGRect {
        guard image.width > 0, image.height > 0 else { return box }
        let k = max(box.width / image.width, box.height / image.height)
        let w = image.width * k, h = image.height * k
        return CGRect(x: box.midX - w / 2, y: box.midY - h / 2, width: w, height: h)
    }

    /// A file pill's icon, name and kind, laid out as `ComposeInlineAttachmentView` does.
    struct FileLabels {
        let icon: NSImage
        let name: NSAttributedString
        let kind: NSAttributedString

        init(_ a: Attachment, width: CGFloat) {
            icon = NSWorkspace.shared.icon(for: UTType(mimeType: a.mimeType) ?? .data)
            name = NSAttributedString(string: ComposeAttachmentStrip.fit(a.fileName, ComposeAttachmentStrip.nameFont, width),
                                      attributes: [.font: ComposeAttachmentStrip.nameFont, .foregroundColor: Fixture.incomingText])
            kind = NSAttributedString(string: ComposeAttachmentStrip.fit(ComposeAttachmentStrip.kindText(a), ComposeAttachmentStrip.kindFont, width),
                                      attributes: [.font: ComposeAttachmentStrip.kindFont, .foregroundColor: Fixture.secondaryText])
        }

        func draw(in r: CGRect) {
            icon.draw(in: CGRect(x: r.minX + 10, y: r.midY - 16, width: 32, height: 32))
            name.draw(at: CGPoint(x: r.minX + 50, y: r.midY))
            kind.draw(at: CGPoint(x: r.minX + 50, y: r.midY - 15))
        }
    }

    /// The thumbnail's long side in pixels at SCALE (no trap on NaN).
    private func thumbnailPixels(_ scale: CGFloat) -> Int {
        CrashGuard.int((max(pictureSize.width, pictureSize.height) * max(1, scale)).rounded(.up))
    }

    /// Decodes the thumbnail now (tests).
    func loadThumbnailNow(scale: CGFloat) {
        guard isImage, let asset = model.asset else { return }
        thumbnailArrived(ComposeAttachmentStrip.thumbnail(asset, maxPixels: thumbnailPixels(scale)))
    }

    /// The attachments' file type, private to the message box.
    static let fileType = "com.cmux.compose.inline-attachment"
    /// Registers `ComposeInlineAttachmentViewProvider` for `fileType`, once.
    private static let registerViewProvider: Void = {
        NSTextAttachment.registerViewProviderClass(ComposeInlineAttachmentViewProvider.self, forFileType: fileType)
    }()

    override func viewProvider(for parentView: NSView?, location: any NSTextLocation, textContainer: NSTextContainer?) -> NSTextAttachmentViewProvider? {
        let provider = ComposeInlineAttachmentViewProvider(textAttachment: self, parentView: parentView, textLayoutManager: textContainer?.textLayoutManager, location: location)
        // The box is the attachment's own (its whole line, `attachmentBounds`), not the view's size.
        provider.tracksTextAttachmentViewBounds = false
        return provider
    }

    /// Whether the field placed this attachment's own view (with its hover remove button), so
    /// the field's hover button (`ComposeInlineRemoveHover`) stays out of its way.
    var showsOwnView: Bool { shownView?.window != nil }

    /// The view that shows this attachment (made by the text view's layout).
    func makeView() -> ComposeInlineAttachmentView {
        let v = ComposeInlineAttachmentView(self)
        shownView = v
        return v
    }
}

final class ComposeInlineAttachmentViewProvider: NSTextAttachmentViewProvider {
    override func loadView() {
        guard let a = textAttachment as? ComposeInlineAttachment else { super.loadView(); return }
        view = a.makeView()
    }
}
