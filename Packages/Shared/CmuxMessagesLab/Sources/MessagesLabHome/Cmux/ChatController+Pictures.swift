import AppKit
import ImageIO

/// cmux: a click on a picture opens it in the large picture viewer (``HomePictureViewer``) over the pane: a picture
/// in a table card with the table's other pictures around it, a picture bubble with the message's other pictures.
/// Send in Chat puts the marked-up picture in the message box, through the same intake as a paste.
extension ChatController {
    /// The viewer open over this pane, if any.
    var pictureViewer: HomePictureViewer? { host.subviews.lazy.compactMap { $0 as? HomePictureViewer }.first }

    /// A click at `point` (in the card's body, top-left origin) on a table card of a body `width` wide whose body
    /// is at `body` in the pane: opens the picture there, growing out of its thumbnail; a Before|After table opens
    /// on its slider. False when the click is not on a loaded picture.
    func openTablePicture(_ part: CustomPart, at point: CGPoint, width: CGFloat, body: CGPoint = .zero) -> Bool {
        guard let source = HomeTableRowProvider.picture(part, at: point, width: width),
              let table = HomeTableRowProvider.payload(part)?.table,
              let gallery = HomePictureGallery(table: table, opening: source) else { return false }
        let grid = HomeTableGrid(table, available: width)
        let thumbnail = grid.pictureRects(at: body).first { $0.source == source }
        let image = grid.slots.lazy.flatMap { $0 }.flatMap { $0 }.first { $0.source == source }?.image
        let from = thumbnail.flatMap { t in image.map { (rect: t.rect, image: $0) } }
        presentPictures(gallery, from: from) { item in await Self.decode(item) }
        return true
    }

    /// A click on the picture bubble `attachment` of `message`: opens it with the message's other pictures.
    func openPictureAttachment(_ message: ID, _ attachment: ID) {
        let pictures = (store?.state.message(message)?.parts ?? []).compactMap { part -> Attachment? in
            if case let .attachment(a) = part, a.kind == "image" { return a }
            return nil
        }
        let items = pictures.enumerated().map { i, a in
            HomePictureGallery.Item(source: HomeMapping.tableAttachmentScheme + a.id, url: URL(fileURLWithPath: a.fileName),
                                    title: a.fileName.isEmpty ? CmuxStrings.pictureUntitled : a.fileName, row: 0, column: i)
        }
        let at = pictures.firstIndex { $0.id == attachment } ?? 0
        guard !items.isEmpty else { intents?.openAttachment(message, attachment); return }
        let intents = intents
        presentPictures(HomePictureGallery(items: items, index: at)) { item in
            let id = String(item.source.dropFirst(HomeMapping.tableAttachmentScheme.count))
            guard let file = await intents?.attachmentFile(message, id) else { return nil }
            var local = item
            local.url = file
            return await Self.decode(local)
        }
    }

    /// Opens `gallery` over this pane through the main-actor seam (``HomePictureViewerMount``).
    private func presentPictures(_ gallery: HomePictureGallery, from thumbnail: (rect: CGRect, image: CGImage)? = nil,
                                 load: @escaping HomePictureViewer.Load) {
        _ = HomePictureViewerMount(host: host).open(gallery, from: thumbnail, load: load, onClose: { [weak self] in
            self?.focusCompose()
        }, onReply: { [weak self] url in
            guard let self else { return }
            let board = HomePictureReply.pasteboard(for: url)
            // The intake reads the pasteboard before it returns (HomeAttachmentIntake.inputs).
            if self.intents?.takeAttachments(from: board) != true { NSSound.beep() }
            board.releaseGlobally()
        })
    }

    /// The full picture of `item`, decoded off the main thread: the local file, else the web picture (downloaded
    /// like a table thumbnail: ephemeral, https, at most ``HomeTablePictures/maxBytes``), else its thumbnail.
    nonisolated static func decode(_ item: HomePictureGallery.Item) async -> CGImage? {
        await Task.detached(priority: .userInitiated) { () -> CGImage? in
            if item.url.isFileURL, let image = image(at: item.url) { return image }
            if item.url.scheme == "https", let file = try? await HomeTablePictures.download(item.url) {
                defer { try? FileManager.default.removeItem(at: file) }
                if let image = image(at: file) { return image }
            }
            return item.thumbnail.flatMap(image(at:))
        }.value
    }

    /// Decodes the picture at `url` upright, at most 8192 px on its long side.
    nonisolated private static func image(at url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(src, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 8192,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary)
    }
}
