import CoreGraphics
import Foundation

/// Rich link metadata for a URL in a message, as Messages shows it: a card
/// with the page image, title and domain. The sender's side fetches it once
/// and every recipient renders the same payload.
public struct ConversationLinkPreview: Sendable, Hashable {
    public struct Image: Sendable, Hashable {
        public var url: URL
        /// Pixel size, used for layout before the bytes arrive.
        public var width: Int
        public var height: Int

        public init(url: URL, width: Int, height: Int) {
            self.url = url
            self.width = width
            self.height = height
        }

        public var aspectRatio: Double {
            guard width > 0, height > 0 else { return 1.91 }
            return Double(width) / Double(height)
        }
    }

    public enum State: Sendable, Hashable {
        /// Metadata is final (it may still be minimal: a bare domain).
        case loaded
        /// Metadata is still being fetched; the card shows a spinner.
        case loading
        /// From someone not in your contacts: nothing loads until tapped.
        case tapToLoad
    }

    public var url: URL
    public var title: String?
    /// Display domain; defaults to the URL host without `www.`.
    public var siteName: String?
    public var image: Image?
    public var icon: Image?
    public var state: State

    public init(url: URL, title: String? = nil, siteName: String? = nil, image: Image? = nil, icon: Image? = nil, state: State = .loaded) {
        self.url = url
        self.title = title
        self.siteName = siteName
        self.image = image
        self.icon = icon
        self.state = state
    }

    public var domain: String {
        if let siteName, !siteName.isEmpty { return siteName }
        let host = url.host ?? url.absoluteString
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// Messages renders an image on top only when it is big enough to look
    /// good at card width; a small one becomes a trailing thumbnail.
    public var showsMediaOnTop: Bool {
        guard state == .loaded, let image else { return false }
        return max(image.width, image.height) >= 150
    }

    /// The trailing thumbnail of a compact card: a small image, else the icon.
    public var thumbnail: Image? {
        guard state == .loaded, !showsMediaOnTop else { return nil }
        return image ?? icon
    }
}

/// How a message with a link preview splits into balloons. Messages sends a
/// URL that opens or ends a message as its own rich link balloon; the rest
/// of the text stays a normal bubble. A URL in the middle stays inline text.
public struct ConversationLinkSplit: Sendable, Hashable {
    /// Text bubble content, without the URL. Empty when the message is only the URL.
    public var bodyText: String
    /// Whether the card comes before the text bubble (the URL opened the message).
    public var cardFirst: Bool

    public static func split(text: String, preview: ConversationLinkPreview?) -> ConversationLinkSplit? {
        guard let preview else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = urlRange(in: trimmed, matching: preview.url) else { return nil }
        if range.lowerBound == trimmed.startIndex {
            let rest = trimmed[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            return ConversationLinkSplit(bodyText: rest, cardFirst: true)
        }
        if range.upperBound == trimmed.endIndex {
            let rest = trimmed[..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            return ConversationLinkSplit(bodyText: rest, cardFirst: false)
        }
        return nil
    }

    nonisolated(unsafe) private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    private static func urlRange(in text: String, matching url: URL) -> Range<String.Index>? {
        var found: Range<String.Index>?
        detector?.enumerateMatches(in: text, range: NSRange(text.startIndex..., in: text)) { match, _, stop in
            guard let match, let matchURL = match.url, let range = Range(match.range, in: text) else { return }
            if normalized(matchURL) == normalized(url) {
                found = range
                stop.pointee = true
            }
        }
        return found
    }

    private static func normalized(_ url: URL) -> String {
        var string = url.absoluteString.lowercased()
        while string.hasSuffix("/") { string.removeLast() }
        if string.hasPrefix("https://") { string.removeFirst(8) } else if string.hasPrefix("http://") { string.removeFirst(7) }
        if string.hasPrefix("www.") { string.removeFirst(4) }
        return string
    }
}

/// Card geometry measured from Apple's RichLinkView (LinkPresentation in
/// the Messages configuration) on iOS 26: frames relative to the card's
/// top-left, excluding the tail drop below the body.
public struct ConversationLinkCardLayout: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case media
        case compact
        case loading
        case tapToLoad
    }

    public var kind: Kind
    /// Card body (no tail drop).
    public var size: CGSize
    public var mediaFrame: CGRect?
    /// Tap-to-load: the darker top area with its prompt.
    public var promptAreaFrame: CGRect?
    public var promptFrame: CGRect?
    public var titleFrame: CGRect?
    public var domainFrame: CGRect?
    public var thumbnailFrame: CGRect?
    /// Fallback glyph for a card with no image or icon.
    public var glyphFrame: CGRect?
    public var spinnerFrame: CGRect?
    public var chevronFrame: CGRect?

    public struct Metrics: Sendable, Hashable {
        public var sideInset: CGFloat = 16
        public var titleTop: CGFloat = 8
        public var titleLineHeight: CGFloat = 18
        public var titleMaxLines = 3
        public var domainGap: CGFloat = 2
        public var domainHeight: CGFloat = 16
        public var captionBottom: CGFloat = 9
        public var narrowWidthFraction: CGFloat = 0.76
        public var thumbnailSize: CGFloat = 30
        public var thumbnailGap: CGFloat = 16
        public var thumbnailTrailing: CGFloat = 12
        public var glyphSize: CGFloat = 32
        public var compactMinHeight: CGFloat = 59
        public var loadingSize = CGSize(width: 150, height: 111)
        public var spinnerSize: CGFloat = 37
        public var spinnerTop: CGFloat = 35
        public var tapPromptHeight: CGFloat = 80
        public var tapCaptionHeight: CGFloat = 35
        public var tapMinWidth: CGFloat = 160
        public var chevronSize = CGSize(width: 10, height: 20)

        public init() {}

        /// iOS 26 Messages (CKUIBehaviorPhone, Dynamic Type L).
        public static let phone = Metrics()
    }

    /// `measureTitle(text, maxWidth)` returns the wrapped title size (unclamped);
    /// `measureDomain(text)` the single-line domain width; `measurePrompt` the tap prompt width.
    public static func compute(
        preview: ConversationLinkPreview,
        maxWidth: CGFloat,
        metrics m: Metrics = .phone,
        measureTitle: (String, CGFloat) -> CGSize,
        measureDomain: (String) -> CGFloat,
        measurePrompt: () -> CGFloat
    ) -> ConversationLinkCardLayout {
        let maxW = floor(maxWidth)
        switch preview.state {
        case .loading:
            let size = m.loadingSize
            let spinner = CGRect(x: (size.width - m.spinnerSize) / 2, y: m.spinnerTop, width: m.spinnerSize, height: m.spinnerSize)
            let domainW = min(size.width - 2 * m.sideInset, ceil(measureDomain(preview.domain)))
            let domain = CGRect(x: (size.width - domainW) / 2, y: spinner.maxY, width: domainW, height: m.domainHeight)
            return ConversationLinkCardLayout(kind: .loading, size: size, spinnerFrame: spinner).with { $0.domainFrame = domain }
        case .tapToLoad:
            let promptW = ceil(measurePrompt())
            let domainW = ceil(measureDomain(preview.domain))
            let w = min(maxW, max(m.tapMinWidth, promptW + 2 * 19, m.sideInset + domainW + 8 + m.chevronSize.width + m.thumbnailTrailing))
            let size = CGSize(width: w, height: m.tapPromptHeight + m.tapCaptionHeight)
            var layout = ConversationLinkCardLayout(kind: .tapToLoad, size: size)
            layout.promptAreaFrame = CGRect(x: 0, y: 0, width: w, height: m.tapPromptHeight)
            let pw = min(promptW, w - 2 * m.sideInset)
            layout.promptFrame = CGRect(x: (w - pw) / 2, y: (m.tapPromptHeight - m.domainHeight) / 2, width: pw, height: m.domainHeight)
            let chevron = CGRect(x: w - m.thumbnailTrailing - m.chevronSize.width, y: m.tapPromptHeight + (m.tapCaptionHeight - m.chevronSize.height) / 2, width: m.chevronSize.width, height: m.chevronSize.height)
            layout.chevronFrame = chevron
            layout.domainFrame = CGRect(x: m.sideInset, y: m.tapPromptHeight + (m.tapCaptionHeight - m.domainHeight) / 2, width: max(0, chevron.minX - 8 - m.sideInset), height: m.domainHeight)
            return layout
        case .loaded:
            break
        }

        func caption(width w: CGFloat, textWidth: CGFloat, top: CGFloat) -> (title: CGRect?, domain: CGRect, height: CGFloat) {
            var y = top + m.titleTop
            var titleFrame: CGRect?
            if let title = preview.title, !title.isEmpty {
                let size = measureTitle(title, textWidth)
                let lines = max(1, min(m.titleMaxLines, Int((size.height / m.titleLineHeight).rounded())))
                let h = CGFloat(lines) * m.titleLineHeight
                titleFrame = CGRect(x: m.sideInset, y: y, width: textWidth, height: h)
                y += h + m.domainGap
            }
            let domain = CGRect(x: m.sideInset, y: y, width: textWidth, height: m.domainHeight)
            return (titleFrame, domain, domain.maxY + m.captionBottom - top)
        }

        if preview.showsMediaOnTop, let image = preview.image {
            let aspect = CGFloat(image.aspectRatio)
            let w = aspect > 1 ? maxW : (maxWidth * m.narrowWidthFraction).rounded()
            let mediaH = floor(w / aspect)
            let cap = caption(width: w, textWidth: w - 2 * m.sideInset, top: mediaH)
            var layout = ConversationLinkCardLayout(kind: .media, size: CGSize(width: w, height: mediaH + cap.height))
            layout.mediaFrame = CGRect(x: 0, y: 0, width: w, height: mediaH)
            layout.titleFrame = cap.title
            layout.domainFrame = cap.domain
            return layout
        }

        // Compact: text column plus a trailing thumbnail (or the fallback glyph).
        let hasThumb = preview.thumbnail != nil
        let accessory = hasThumb ? m.thumbnailSize : m.glyphSize
        let chrome = m.sideInset + m.thumbnailGap + accessory + m.thumbnailTrailing
        let maxText = maxW - chrome
        var textW = ceil(measureDomain(preview.domain))
        if let title = preview.title, !title.isEmpty {
            textW = max(textW, ceil(measureTitle(title, maxText).width))
        }
        textW = min(textW, maxText)
        let w = textW + chrome
        var cap = caption(width: w, textWidth: textW, top: 0)
        let h = max(m.compactMinHeight, cap.height)
        if h > cap.height {
            // Center the text block when the accessory sets the height.
            let block = cap.domain.maxY - (cap.title?.minY ?? cap.domain.minY)
            let shift = ((h - block) / 2).rounded() - m.titleTop
            cap.title = cap.title?.offsetBy(dx: 0, dy: shift)
            cap.domain = cap.domain.offsetBy(dx: 0, dy: shift)
        }
        var layout = ConversationLinkCardLayout(kind: .compact, size: CGSize(width: w, height: h))
        layout.titleFrame = cap.title
        layout.domainFrame = cap.domain
        let accessoryFrame = CGRect(x: w - m.thumbnailTrailing - accessory, y: (h - accessory) / 2, width: accessory, height: accessory)
        if hasThumb { layout.thumbnailFrame = accessoryFrame } else { layout.glyphFrame = accessoryFrame }
        return layout
    }

    private func with(_ change: (inout ConversationLinkCardLayout) -> Void) -> ConversationLinkCardLayout {
        var copy = self
        change(&copy)
        return copy
    }
}

/// Caption tint for a card, from the image's average color. Messages tints
/// the caption with the image's dominant color (iOS 26 bubble tinting) and
/// draws the title near-white over it.
public enum ConversationLinkTint {
    /// `rgb` is the average image color (0...1). Returns the caption color.
    public static func caption(fromAverage rgb: (r: Double, g: Double, b: Double)) -> (r: Double, g: Double, b: Double) {
        let maxC = max(rgb.r, rgb.g, rgb.b)
        guard maxC > 0.02 else { return (0.2, 0.2, 0.2) }
        // Same hue, settled where white text reads. Measured against
        // LinkPresentation: averages peaking at 0.79 and 1.0 rendered at 0.69
        // and 0.90; a gray floor keeps near-black images readable.
        let brightness = min(0.9, max(0.25, maxC * 0.88))
        let scale = brightness / maxC
        return (rgb.r * scale, rgb.g * scale, rgb.b * scale)
    }

    /// Domain text over a tinted caption: the caption hue, light and desaturated.
    public static func domain(onCaption rgb: (r: Double, g: Double, b: Double)) -> (r: Double, g: Double, b: Double) {
        func lift(_ value: Double, max maxC: Double) -> Double {
            guard maxC > 0 else { return 0.75 }
            let normalized = value / maxC
            return 0.26 + 0.73 * normalized
        }
        let maxC = max(rgb.r, rgb.g, rgb.b)
        return (lift(rgb.r, max: maxC), lift(rgb.g, max: maxC), lift(rgb.b, max: maxC))
    }
}
