#if canImport(UIKit)
import CmuxConversationCore
import QuickLookThumbnailing
import UIKit
import UniformTypeIdentifiers

/// Messages' document balloon (`CKAttachmentBalloonView`), sized from
/// ChatKit's iOS 26.5 behaviors: `attachmentBalloonSize` 187 x 124.67 pt in
/// the received-balloon gray for both directions (`attachmentBalloonFillColor`,
/// no stroke), the Quick Look thumbnail inside `attachmentBalloonRichIconInsets`
/// (30.32 pt top and bottom, 16 pt sides), `documentIconSize` 31 x 37 pt for
/// the generic icon. The name and "type · size" sit under the thumbnail.
enum ConversationFileBubbleLayout {
    static let size = CGSize(width: 187, height: 124.666_666_666_666_67)
    /// The thumbnail's box: the rich icon insets, raised to leave the text room.
    static let thumbnailBox = CGRect(x: 16, y: 12, width: 155, height: 58)
    static let documentIconSize = CGSize(width: 31, height: 37)
    /// Quick Look draws a document page to fill the requested size, so ask
    /// for a page-shaped thumbnail as tall as the box (photos fit inside it).
    static var thumbnailRequestSize: CGSize { CGSize(width: (thumbnailBox.height * 0.8).rounded(), height: thumbnailBox.height) }
    static let nameFont = UIFont.systemFont(ofSize: 15, weight: .semibold)
    static let detailFont = UIFont.systemFont(ofSize: 12)

    /// "PDF Document · 15 KB".
    static func detail(for file: ConversationFileInfo) -> String {
        "\(file.typeDescription) · \(file.formattedSize)"
    }
}

/// Quick Look thumbnails for attachments, cached by attachment id.
@MainActor
final class ConversationFileThumbnailer {
    static let shared = ConversationFileThumbnailer()
    private let cache = NSCache<NSString, UIImage>()
    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    func cached(_ attachment: ConversationAttachment, size: CGSize) -> UIImage? {
        cache.object(forKey: key(attachment, size) as NSString)
    }

    func thumbnail(for attachment: ConversationAttachment, size: CGSize, scale: CGFloat) async -> UIImage? {
        let key = key(attachment, size)
        if let image = cache.object(forKey: key as NSString) { return image }
        if let task = inFlight[key] { return await task.value }
        let task = Task<UIImage?, Never> { @MainActor in
            guard let url = await ConversationImageLoader.shared.fileURL(for: attachment) else { return nil }
            return await Self.generate(url: url, size: size, scale: scale)
        }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        if let image { cache.setObject(image, forKey: key as NSString) }
        return image
    }

    /// A thumbnail for a local file (the composer's picked files).
    static func generate(url: URL, size: CGSize, scale: CGFloat) async -> UIImage? {
        let request = QLThumbnailGenerator.Request(fileAt: url, size: size, scale: scale, representationTypes: .all)
        return await withCheckedContinuation { continuation in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
                guard let representation else { return continuation.resume(returning: nil) }
                // Mark real previews (a page, a photo) so they get an edge; icons do not.
                representation.uiImage.accessibilityIdentifier = representation.type == .thumbnail ? "thumbnail" : "icon"
                continuation.resume(returning: representation.uiImage)
            }
        }
    }

    /// The system's icon for a type, when no thumbnail exists yet.
    static func icon(for file: ConversationFileInfo) -> UIImage? {
        let symbol: String
        switch file.type {
        case let type where type.conforms(to: .pdf): symbol = "doc.richtext"
        case let type where type.conforms(to: .archive): symbol = "doc.zipper"
        case let type where type.conforms(to: .text): symbol = "doc.text"
        case let type where type.conforms(to: .image): symbol = "photo"
        case let type where type.conforms(to: .audiovisualContent): symbol = "film"
        default: symbol = "doc"
        }
        return UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 30, weight: .light))
    }

    private func key(_ attachment: ConversationAttachment, _ size: CGSize) -> String {
        "\(attachment.id)@\(Int(size.width))x\(Int(size.height))"
    }
}

/// The document balloon in a transcript row.
final class ConversationFileBubbleView: UIView {
    private let background = BubbleBackgroundView()
    let thumbnailView = UIImageView()
    private let nameLabel = UILabel()
    private let detailLabel = UILabel()
    private var task: Task<Void, Never>?
    private(set) var attachment: ConversationAttachment?

    override init(frame: CGRect) {
        super.init(frame: frame)
        background.fillColor = ConversationTheme.incomingBubble
        addSubview(background)
        thumbnailView.contentMode = .scaleAspectFit
        thumbnailView.tintColor = .secondaryLabel
        thumbnailView.layer.cornerCurve = .continuous
        thumbnailView.clipsToBounds = true
        addSubview(thumbnailView)
        nameLabel.font = ConversationFileBubbleLayout.nameFont
        nameLabel.textColor = .label
        nameLabel.textAlignment = .center
        nameLabel.lineBreakMode = .byTruncatingMiddle
        addSubview(nameLabel)
        detailLabel.font = ConversationFileBubbleLayout.detailFont
        detailLabel.textColor = .secondaryLabel
        detailLabel.textAlignment = .center
        addSubview(detailLabel)
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ attachment: ConversationAttachment, side: BubbleShape.Side, tailed: Bool) {
        background.side = side
        background.hasTail = tailed
        guard self.attachment?.id != attachment.id || thumbnailView.image == nil else { return }
        self.attachment = attachment
        task?.cancel()
        let file = attachment.file ?? ConversationFileInfo(name: attachment.id, uti: UTType.data.identifier, byteCount: 0)
        nameLabel.text = file.name
        detailLabel.text = ConversationFileBubbleLayout.detail(for: file)
        accessibilityLabel = "\(file.name), \(ConversationFileBubbleLayout.detail(for: file))"
        let box = ConversationFileBubbleLayout.thumbnailRequestSize
        if let cached = ConversationFileThumbnailer.shared.cached(attachment, size: box) {
            show(thumbnail: cached)
            return
        }
        thumbnailView.image = ConversationFileThumbnailer.icon(for: file)
        thumbnailView.layer.borderWidth = 0
        let scale = window?.screen.scale ?? 3
        task = Task { @MainActor [weak self] in
            guard let image = await ConversationFileThumbnailer.shared.thumbnail(for: attachment, size: box, scale: scale),
                  let self, !Task.isCancelled, self.attachment?.id == attachment.id else { return }
            self.show(thumbnail: image)
        }
    }

    private func show(thumbnail: UIImage) {
        thumbnailView.image = thumbnail
        // A page thumbnail gets a hairline edge, like ChatKit's rich icon outline.
        thumbnailView.layer.borderWidth = thumbnail.accessibilityIdentifier == "thumbnail" ? 1 / max(traitCollection.displayScale, 1) : 0
        thumbnailView.layer.borderColor = UIColor.separator.cgColor
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        background.frame = bounds
        let tailWidth = ConversationTheme.tailWidth
        let bodyX: CGFloat = background.side == .leading ? tailWidth : 0
        let box = ConversationFileBubbleLayout.thumbnailBox.offsetBy(dx: bodyX, dy: 0)
        if let image = thumbnailView.image, image.size.width > 0, image.size.height > 0 {
            let scale = min(box.width / image.size.width, box.height / image.size.height, thumbnailView.layer.borderWidth > 0 ? .greatestFiniteMagnitude : 1)
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            thumbnailView.frame = CGRect(x: box.midX - size.width / 2, y: box.midY - size.height / 2, width: size.width, height: size.height).integral
        }
        let width = ConversationFileBubbleLayout.size.width - 24
        nameLabel.frame = CGRect(x: bodyX + 12, y: box.maxY + 8, width: width, height: ceil(nameLabel.font.lineHeight))
        detailLabel.frame = CGRect(x: bodyX + 12, y: nameLabel.frame.maxY + 2, width: width, height: ceil(detailLabel.font.lineHeight))
    }
}

/// A picked document in the composer's attachment card: the thumbnail over
/// its name and "type · size", on the card's rounded tile.
final class ComposerFileChipView: UIView {
    let thumbnailView = UIImageView()
    private let nameLabel = UILabel()
    private let detailLabel = UILabel()

    /// The chip's width for the card's `height`, the document balloon's aspect.
    static func width(forHeight height: CGFloat) -> CGFloat {
        (height * ConversationFileBubbleLayout.size.width / ConversationFileBubbleLayout.size.height).rounded()
    }

    init(file: ConversationFileInfo, url: URL?) {
        super.init(frame: .zero)
        backgroundColor = ConversationTheme.incomingBubble
        layer.cornerRadius = 12
        layer.cornerCurve = .continuous
        clipsToBounds = true
        thumbnailView.contentMode = .scaleAspectFit
        thumbnailView.tintColor = .secondaryLabel
        thumbnailView.image = ConversationFileThumbnailer.icon(for: file)
        addSubview(thumbnailView)
        nameLabel.text = file.name
        nameLabel.font = ConversationFileBubbleLayout.nameFont
        nameLabel.textAlignment = .center
        nameLabel.lineBreakMode = .byTruncatingMiddle
        addSubview(nameLabel)
        detailLabel.text = ConversationFileBubbleLayout.detail(for: file)
        detailLabel.font = ConversationFileBubbleLayout.detailFont
        detailLabel.textColor = .secondaryLabel
        detailLabel.textAlignment = .center
        addSubview(detailLabel)
        isAccessibilityElement = true
        accessibilityLabel = "\(file.name), \(ConversationFileBubbleLayout.detail(for: file))"
        accessibilityIdentifier = "conversation.composer.file"
        if let url {
            Task { @MainActor [weak self] in
                guard let image = await ConversationFileThumbnailer.generate(url: url, size: CGSize(width: 72, height: 90), scale: 3) else { return }
                self?.thumbnailView.image = image
                self?.setNeedsLayout()
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let textHeight = ceil(nameLabel.font.lineHeight) + 2 + ceil(detailLabel.font.lineHeight)
        let box = CGRect(x: 14, y: 14, width: bounds.width - 28, height: max(20, bounds.height - 28 - textHeight - 8))
        if let image = thumbnailView.image, image.size.width > 0 {
            let scale = min(box.width / image.size.width, box.height / image.size.height)
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            thumbnailView.frame = CGRect(x: box.midX - size.width / 2, y: box.midY - size.height / 2, width: size.width, height: size.height).integral
        }
        nameLabel.frame = CGRect(x: 10, y: box.maxY + 8, width: bounds.width - 20, height: ceil(nameLabel.font.lineHeight))
        detailLabel.frame = CGRect(x: 10, y: nameLabel.frame.maxY + 2, width: bounds.width - 20, height: ceil(detailLabel.font.lineHeight))
    }
}
#endif
