#if canImport(UIKit)
import CmuxConversationCore
import UIKit

/// Rich link balloon, drawn like Messages' RichLinkView: page image on top
/// (or a trailing thumbnail), a caption tinted with the image's color, the
/// title and domain, all inside the bubble outline. Frames come from
/// `ConversationLinkCardLayout`.
final class ConversationLinkPreviewView: UIView {
    static let titleFont = UIFont.systemFont(ofSize: 15, weight: .semibold)
    static let domainFont = UIFont.systemFont(ofSize: 13)

    private let fill = CAShapeLayer()
    private let shapeMask = CAShapeLayer()
    private let mediaView = UIImageView()
    private let promptArea = UIView()
    private let promptLabel = UILabel()
    private let titleLabel = UILabel()
    private let domainLabel = UILabel()
    private let thumbnailView = UIImageView()
    private let glyphView = UIImageView(image: UIImage(systemName: "safari.fill"))
    private let chevronView = UIImageView(image: UIImage(systemName: "chevron.right"))
    private let spinner = UIActivityIndicatorView(style: .large)

    private(set) var preview: ConversationLinkPreview?
    private var cardLayout: ConversationLinkCardLayout?
    private var side: BubbleShape.Side = .leading
    private var hasTail = false
    private var tint: UIColor?
    private var imageTask: Task<Void, Never>?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        layer.addSublayer(fill)
        layer.mask = shapeMask
        mediaView.contentMode = .scaleAspectFill
        mediaView.clipsToBounds = true
        mediaView.backgroundColor = UIColor.secondarySystemFill
        thumbnailView.contentMode = .scaleAspectFill
        thumbnailView.clipsToBounds = true
        thumbnailView.layer.cornerRadius = 4
        thumbnailView.layer.cornerCurve = .continuous
        glyphView.contentMode = .scaleAspectFit
        glyphView.tintColor = ConversationTheme.secondaryText
        chevronView.contentMode = .scaleAspectFit
        chevronView.tintColor = ConversationTheme.secondaryText
        chevronView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        promptArea.backgroundColor = Self.promptFill
        promptLabel.font = Self.domainFont
        promptLabel.textColor = .label
        promptLabel.textAlignment = .center
        promptLabel.text = Self.promptText
        titleLabel.font = Self.titleFont
        titleLabel.numberOfLines = 3
        titleLabel.lineBreakMode = .byTruncatingTail
        domainLabel.font = Self.domainFont
        domainLabel.lineBreakMode = .byTruncatingTail
        spinner.hidesWhenStopped = true
        for view in [mediaView, promptArea, promptLabel, titleLabel, domainLabel, thumbnailView, glyphView, chevronView, spinner] as [UIView] {
            addSubview(view)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    static let promptText = String(localized: "conversation.link.tapToLoad", defaultValue: "Tap to Load Preview", bundle: .module)

    /// The darker top of a Tap to Load card (measured 219/219/222 in light mode).
    static let promptFill = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 46 / 255, green: 45 / 255, blue: 50 / 255, alpha: 1)
            : UIColor(red: 219 / 255, green: 219 / 255, blue: 222 / 255, alpha: 1)
    }

    static func layout(for preview: ConversationLinkPreview, maxWidth: CGFloat) -> ConversationLinkCardLayout {
        ConversationLinkCardLayout.compute(
            preview: preview,
            maxWidth: maxWidth,
            measureTitle: { text, width in
                let rect = (text as NSString).boundingRect(
                    with: CGSize(width: width, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: [.font: titleFont],
                    context: nil
                )
                // UIKit lines are 18 pt for 15 pt semibold, as in LinkPresentation.
                let lines = max(1, (rect.height / titleFont.lineHeight).rounded())
                return CGSize(width: ceil(rect.width), height: lines * 18)
            },
            measureDomain: { text in ceil((text as NSString).size(withAttributes: [.font: domainFont]).width) },
            measurePrompt: { ceil((promptText as NSString).size(withAttributes: [.font: domainFont]).width) }
        )
    }

    /// `frame` (set by the caller) includes the tail area on `side`.
    func configure(preview: ConversationLinkPreview, layout: ConversationLinkCardLayout, side: BubbleShape.Side, tail: Bool) {
        let sameLink = self.preview?.url == preview.url
        let sameImage = sameLink && self.preview?.image == preview.image && self.preview?.icon == preview.icon
        self.preview = preview
        cardLayout = layout
        self.side = side
        hasTail = tail
        if !sameLink { tint = Self.tintCache[preview.url] }

        let origin = CGPoint(x: side == .leading ? ConversationTheme.tailWidth : 0, y: 0)
        func place(_ view: UIView, _ rect: CGRect?) {
            view.isHidden = rect == nil
            if let rect { view.frame = rect.offsetBy(dx: origin.x, dy: origin.y) }
        }
        place(mediaView, layout.mediaFrame)
        place(promptArea, layout.promptAreaFrame)
        place(promptLabel, layout.promptFrame)
        place(titleLabel, layout.titleFrame)
        place(domainLabel, layout.domainFrame)
        place(thumbnailView, layout.thumbnailFrame)
        place(glyphView, layout.glyphFrame)
        place(chevronView, layout.chevronFrame)
        place(spinner, layout.spinnerFrame)
        titleLabel.text = preview.title
        domainLabel.text = preview.domain
        domainLabel.textAlignment = layout.kind == .loading ? .center : .natural
        if layout.kind == .loading { spinner.startAnimating() } else { spinner.stopAnimating() }

        if !sameImage {
            mediaView.image = nil
            thumbnailView.image = nil
            loadImages()
        }
        applyColors()
        setNeedsLayout()
        accessibilityLabel = [preview.title, preview.domain].compactMap { $0 }.joined(separator: ", ")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        var rect = bounds
        if hasTail { rect.size.height -= ConversationTheme.tailDrop }
        let path = BubbleShape.path(in: rect, side: side, tail: hasTail).cgPath
        fill.frame = bounds
        fill.path = path
        shapeMask.frame = bounds
        shapeMask.path = path
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        applyColors()
    }

    private func applyColors() {
        let tinted = tint != nil && cardLayout?.kind != .tapToLoad && cardLayout?.kind != .loading
        let background = tinted ? tint! : ConversationTheme.incomingBubble
        fill.fillColor = background.resolvedColor(with: traitCollection).cgColor
        if tinted, let components = tint?.rgb {
            titleLabel.textColor = UIColor(red: 248 / 255, green: 247 / 255, blue: 250 / 255, alpha: 1)
            let domain = ConversationLinkTint.domain(onCaption: components)
            domainLabel.textColor = UIColor(red: domain.r, green: domain.g, blue: domain.b, alpha: 1)
        } else {
            titleLabel.textColor = .label
            domainLabel.textColor = ConversationTheme.secondaryText
        }
    }

    private func loadImages() {
        imageTask?.cancel()
        guard let preview, preview.state == .loaded else { return }
        let media = preview.showsMediaOnTop ? preview.image : nil
        let thumb = preview.thumbnail
        guard media != nil || thumb != nil else { return }
        let scale = window?.screen.scale ?? 3
        let url = preview.url
        imageTask = Task { @MainActor [weak self] in
            if let media, let self {
                let image = await ConversationImageLoader.shared.image(for: Self.attachment(media), pixelWidth: max(self.mediaView.bounds.width, 1) * scale)
                guard !Task.isCancelled, self.preview?.url == url else { return }
                self.mediaView.image = image
                self.adoptTint(from: image, url: url)
            }
            if let thumb, let self {
                let image = await ConversationImageLoader.shared.image(for: Self.attachment(thumb), pixelWidth: 30 * scale)
                guard !Task.isCancelled, self.preview?.url == url else { return }
                self.thumbnailView.image = image
                self.adoptTint(from: image, url: url)
            }
        }
    }

    private func adoptTint(from image: UIImage?, url: URL) {
        guard tint == nil, let image, let average = image.averageColor else { return }
        let caption = ConversationLinkTint.caption(fromAverage: average)
        let color = UIColor(red: caption.r, green: caption.g, blue: caption.b, alpha: 1)
        Self.tintCache[url] = color
        tint = color
        UIView.transition(with: self, duration: 0.2, options: [.transitionCrossDissolve, .allowUserInteraction]) {
            self.applyColors()
        }
    }

    private static var tintCache: [URL: UIColor] = [:]

    private static func attachment(_ image: ConversationLinkPreview.Image) -> ConversationAttachment {
        ConversationAttachment(id: "lp:\(image.url.absoluteString)", kind: .image, width: image.width, height: image.height, url: image.url)
    }
}

private extension UIColor {
    var rgb: (r: Double, g: Double, b: Double)? {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard getRed(&r, green: &g, blue: &b, alpha: &a) else { return nil }
        return (Double(r), Double(g), Double(b))
    }
}

private extension UIImage {
    /// Mean color, from an 8x8 downsample.
    var averageColor: (r: Double, g: Double, b: Double)? {
        guard let cgImage else { return nil }
        let side = 8
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }
        var sum = (r: 0.0, g: 0.0, b: 0.0, a: 0.0)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            sum.r += Double(pixels[i]); sum.g += Double(pixels[i + 1]); sum.b += Double(pixels[i + 2]); sum.a += Double(pixels[i + 3])
        }
        guard sum.a > 0 else { return nil }
        return (sum.r / sum.a, sum.g / sum.a, sum.b / sum.a)
    }
}
#endif
