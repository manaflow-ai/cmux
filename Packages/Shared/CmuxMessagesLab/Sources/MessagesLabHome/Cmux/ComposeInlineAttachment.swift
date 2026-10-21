// cmux: one attachment in the message box's text (Draft+InlineMarks.swift). Not a vendored file.
import AppKit

/// One attachment in the field's text: an image's thumbnail or a file's pill,
/// drawn by `ComposeInlineAttachmentView`.
final class ComposeInlineAttachment: NSTextAttachment {
    let attachmentID: ID
    private(set) var model: Attachment
    /// The remove button's action (the field deletes the mark).
    var onRemove: (ID) -> Void = { _ in }
    /// The thumbnail, once decoded (nil: the placeholder grey).
    private(set) var thumbnail: CGImage?
    private weak var shownView: ComposeInlineAttachmentView?

    init(_ a: Attachment, scale: CGFloat) {
        attachmentID = a.id
        model = a
        super.init(data: nil, ofType: nil)
        let size = Self.size(of: a, scale: scale)
        bounds = CGRect(x: 0, y: Self.baselineOffset, width: size.width, height: size.height)
        allowsTextAttachmentView = true
        loadThumbnail(scale: scale)
    }

    required init?(coder: NSCoder) { nil }

    var isImage: Bool { ComposeAttachmentStrip.isImage(model) }

    /// The attachment's box below the baseline (it sits on the text line, a little low, as in Messages).
    static let baselineOffset: CGFloat = -4

    /// Images: aspect-fit in the strip's 128 x 64 pt box; files: the 200 x 52 pt pill.
    static func size(of a: Attachment, scale: CGFloat) -> CGSize {
        guard ComposeAttachmentStrip.isImage(a) else {
            return CGSize(width: ComposeAttachmentStrip.fileWidth, height: ComposeAttachmentStrip.fileHeight)
        }
        let s = max(1, scale)
        let w = CGFloat(a.width ?? 1) / s, h = CGFloat(a.height ?? 1) / s
        let k = min(1, ComposeAttachmentStrip.boxWidth / w, ComposeAttachmentStrip.imageMaxHeight / h)
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
        // task-owner: one decode per attachment, off the main actor; ends with the image.
        Task { [weak self] in
            let image = await Task.detached(priority: .userInitiated) {
                ComposeAttachmentStrip.thumbnail(asset, maxPixels: px)
            }.value
            guard let self, self.model.asset == asset else { return }
            self.thumbnail = image
            self.shownView?.show(image)
        }
    }

    /// The thumbnail's long side in pixels at SCALE (no trap on NaN).
    private func thumbnailPixels(_ scale: CGFloat) -> Int {
        CrashGuard.int((max(bounds.width, bounds.height) * max(1, scale)).rounded(.up))
    }

    /// Decodes the thumbnail now (tests).
    func loadThumbnailNow(scale: CGFloat) {
        guard isImage, let asset = model.asset else { return }
        thumbnail = ComposeAttachmentStrip.thumbnail(asset, maxPixels: thumbnailPixels(scale))
    }

    override func viewProvider(for parentView: NSView?, location: any NSTextLocation, textContainer: NSTextContainer?) -> NSTextAttachmentViewProvider? {
        let provider = ComposeInlineAttachmentViewProvider(textAttachment: self, parentView: parentView, textLayoutManager: textContainer?.textLayoutManager, location: location)
        provider.tracksTextAttachmentViewBounds = true
        return provider
    }

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
