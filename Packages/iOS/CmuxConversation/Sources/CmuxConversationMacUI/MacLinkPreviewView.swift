#if os(macOS)
import AppKit
import CmuxConversationCore
import CmuxConversationGeometry

/// Rich link balloon for the macOS transcript, matching LinkPresentation's
/// Mac metrics (11 pt semibold title, 10 pt domain, 10 pt insets) inside the
/// Messages bubble outline. Frames come from `ConversationLinkCardLayout`.
final class MacLinkPreviewView: MacFlippedView {
    static let titleFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
    static let domainFont = NSFont.systemFont(ofSize: 10)

    private let fill = CAShapeLayer()
    private let shapeMask = CAShapeLayer()
    private let mediaView = NSImageView()
    private let promptArea = MacFlippedView()
    private let promptLabel = MacMeasuredTextView()
    private let titleLabel = MacMeasuredTextView()
    private let domainLabel = MacMeasuredTextView()
    private let thumbnailView = NSImageView()
    private let glyphView = NSImageView()
    private let chevronView = NSImageView()
    private let spinner = NSProgressIndicator()

    private(set) var preview: ConversationLinkPreview?
    private var cardLayout: ConversationLinkCardLayout?
    private var side: ConversationBubbleGeometry.Side = .leading
    private var hasTail = false
    private var tint: NSColor?
    private var imageTask: Task<Void, Never>?

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer?.addSublayer(fill)
        layer?.mask = shapeMask
        for view in [mediaView, thumbnailView] {
            view.imageScaling = .scaleAxesIndependently
            view.wantsLayer = true
            view.layer?.contentsGravity = .resizeAspectFill
            view.layer?.masksToBounds = true
        }
        mediaView.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        thumbnailView.layer?.cornerRadius = 4
        glyphView.image = NSImage(systemSymbolName: "safari.fill", accessibilityDescription: nil)
        glyphView.symbolConfiguration = .init(pointSize: 26, weight: .regular)
        glyphView.contentTintColor = MacConversationTheme.secondaryText
        chevronView.image = NSImage(systemSymbolName: "chevron.forward", accessibilityDescription: nil)
        chevronView.symbolConfiguration = .init(pointSize: 9, weight: .semibold)
        chevronView.contentTintColor = MacConversationTheme.secondaryText
        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.isDisplayedWhenStopped = false
        for view in [mediaView, promptArea, promptLabel, titleLabel, domainLabel, thumbnailView, glyphView, chevronView, spinner] as [NSView] {
            addSubview(view)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    static let promptText = String(localized: "conversation.link.clickToLoad", defaultValue: "Click to Load Preview", bundle: .module)

    static let promptFill = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.18, green: 0.18, blue: 0.2, alpha: 1)
            : NSColor(srgbRed: 219 / 255, green: 219 / 255, blue: 222 / 255, alpha: 1)
    }

    static func layout(for preview: ConversationLinkPreview, maxWidth: CGFloat) -> ConversationLinkCardLayout {
        ConversationLinkCardLayout.compute(
            preview: preview,
            maxWidth: maxWidth,
            metrics: .mac,
            measureTitle: { text, width in
                let rect = NSAttributedString(string: text, attributes: [.font: titleFont]).boundingRect(
                    with: CGSize(width: width, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading]
                )
                let lines = max(1, (rect.height / (titleFont.ascender - titleFont.descender + titleFont.leading)).rounded())
                return CGSize(width: ceil(rect.width), height: lines * 14)
            },
            measureDomain: { ceil(($0 as NSString).size(withAttributes: [.font: domainFont]).width) },
            measurePrompt: { ceil((promptText as NSString).size(withAttributes: [.font: domainFont]).width) }
        )
    }

    /// `frame` (set by the caller) includes the tail drop when `tail` is set.
    func configure(preview: ConversationLinkPreview, layout: ConversationLinkCardLayout, side: ConversationBubbleGeometry.Side, tail: Bool) {
        let sameLink = self.preview?.url == preview.url
        let sameImage = sameLink && self.preview?.image == preview.image && self.preview?.icon == preview.icon
        self.preview = preview
        cardLayout = layout
        self.side = side
        hasTail = tail
        if !sameLink { tint = Self.tintCache[preview.url] }
        let dx = side == .leading ? MacConversationTheme.tailWidth : 0
        func place(_ view: NSView, _ rect: CGRect?) {
            view.isHidden = rect == nil
            if let rect { view.frame = rect.offsetBy(dx: dx, dy: 0) }
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
        if layout.kind == .loading { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        if !sameImage {
            mediaView.image = nil
            thumbnailView.image = nil
            loadImages(layout: layout)
        }
        applyColors()
        updateShape()
        setAccessibilityLabel([preview.title, preview.domain].compactMap { $0 }.joined(separator: ", "))
    }

    override func layout() {
        super.layout()
        updateShape()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func updateShape() {
        var rect = bounds
        if hasTail { rect.size.height -= MacConversationTheme.tailDrop }
        let path = ConversationBubbleGeometry.path(
            in: rect, side: side, tail: hasTail,
            radius: MacConversationTheme.bubbleCornerRadius, tailWidth: MacConversationTheme.tailWidth,
            tailDrop: MacConversationTheme.tailDrop, style: .macOS
        )
        fill.frame = bounds
        fill.path = path
        shapeMask.frame = bounds
        shapeMask.path = path
    }

    private func applyColors() {
        guard let preview, let cardLayout else { return }
        let tinted = tint != nil && cardLayout.kind != .tapToLoad && cardLayout.kind != .loading
        var fillColor = MacConversationTheme.incomingBubble.cgColor
        var promptColor = Self.promptFill.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            fillColor = (tinted ? self.tint! : MacConversationTheme.incomingBubble).cgColor
            promptColor = Self.promptFill.cgColor
        }
        fill.fillColor = fillColor
        promptArea.layer?.backgroundColor = promptColor
        let titleColor: NSColor
        let domainColor: NSColor
        if tinted, let rgb = tint?.usingColorSpace(.sRGB) {
            titleColor = NSColor(srgbRed: 248 / 255, green: 247 / 255, blue: 250 / 255, alpha: 1)
            let d = ConversationLinkTint.domain(onCaption: (Double(rgb.redComponent), Double(rgb.greenComponent), Double(rgb.blueComponent)))
            domainColor = NSColor(srgbRed: d.r, green: d.g, blue: d.b, alpha: 1)
        } else {
            titleColor = .labelColor
            domainColor = MacConversationTheme.secondaryText
        }
        let titleStyle = NSMutableParagraphStyle()
        titleStyle.minimumLineHeight = 14
        titleStyle.maximumLineHeight = 14
        titleStyle.lineBreakMode = .byWordWrapping
        titleLabel.attributedText = NSAttributedString(string: preview.title ?? "", attributes: [.font: Self.titleFont, .foregroundColor: titleColor, .paragraphStyle: titleStyle])
        let domainStyle = NSMutableParagraphStyle()
        domainStyle.alignment = cardLayout.kind == .loading ? .center : .natural
        domainStyle.lineBreakMode = .byTruncatingTail
        domainLabel.attributedText = NSAttributedString(string: preview.domain, attributes: [.font: Self.domainFont, .foregroundColor: domainColor, .paragraphStyle: domainStyle])
        promptLabel.attributedText = NSAttributedString(string: Self.promptText, attributes: [.font: Self.domainFont, .foregroundColor: NSColor.labelColor])
    }

    private func loadImages(layout: ConversationLinkCardLayout) {
        imageTask?.cancel()
        guard let preview, preview.state == .loaded else { return }
        let media = layout.mediaFrame != nil ? preview.image : nil
        let thumb = layout.thumbnailFrame != nil ? (preview.icon ?? preview.image) : nil
        guard media != nil || thumb != nil else { return }
        let url = preview.url
        imageTask = Task { @MainActor [weak self] in
            for (image, view) in [(media, self?.mediaView), (thumb, self?.thumbnailView)] {
                guard let image, let view else { continue }
                let loaded = await MacImageLoader.shared.image(for: Self.attachment(image))
                guard let self, !Task.isCancelled, self.preview?.url == url else { return }
                view.layer?.contents = loaded
                self.adoptTint(from: loaded, url: url)
            }
        }
    }

    private func adoptTint(from image: NSImage?, url: URL) {
        guard tint == nil, let average = image?.averageColor else { return }
        let caption = ConversationLinkTint.caption(fromAverage: average)
        let color = NSColor(srgbRed: caption.r, green: caption.g, blue: caption.b, alpha: 1)
        Self.tintCache[url] = color
        tint = color
        applyColors()
    }

    private static var tintCache: [URL: NSColor] = [:]

    private static func attachment(_ image: ConversationLinkPreview.Image) -> ConversationAttachment {
        ConversationAttachment(id: "lp:\(image.url.absoluteString)", kind: .image, width: image.width, height: image.height, url: image.url)
    }
}

private extension NSImage {
    var averageColor: (r: Double, g: Double, b: Double)? {
        guard let cgImage = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
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
