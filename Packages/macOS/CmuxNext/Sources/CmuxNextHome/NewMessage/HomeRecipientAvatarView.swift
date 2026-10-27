public import AppKit
import CmuxNextCompat
import CmuxNextDesign
import ImageIO

/// How a suggestion row under New Message's To: field draws one recipient
/// beyond its name: its avatar, and a tag after what it is on the line under
/// the name ("Chief · Main · Cloud"). The page knows both (the Chief's avatar
/// and where it runs); a recipient it says nothing about draws its initials
/// and its source alone.
public nonisolated struct HomeRecipientLook: Hashable, Sendable {
    /// The Chief's avatar; nil draws the name's initials.
    public var avatar: HomeChiefAvatar?
    /// Where a Chief runs, after "Chief" under the name; nil shows the source alone.
    public var tag: String?

    public init(avatar: HomeChiefAvatar? = nil, tag: String? = nil) {
        self.avatar = avatar
        self.tag = tag
    }
}

// memory: fixed one picture per Chief the list suggests (the roster), each at most 96 x 96 px
// (36 KiB); the suggestions list owns it and frees it with itself.

/// The avatar pictures one New Message list has read, by file: the list rebuilds its rows on every
/// keystroke, so each picture is read once per list. Each is downsampled to at most
/// ``maxPixel`` pixels a side as it is read.
final class HomeRecipientPictures {
    /// The longest side a picture is kept at: the 28 pt disc at 3x, rounded up.
    nonisolated static let maxPixel = 96

    private var pictures: [URL: NSImage] = [:]

    /// The picture read from `url`, or nil before it is read.
    func picture(_ url: URL) -> NSImage? { pictures[url] }

    /// Keeps `image` as the picture of `url`.
    func keep(_ image: NSImage, for url: URL) { pictures[url] = image }
}

/// A suggestion row's avatar disc: the Chief's picture or text avatar (an
/// emoji on the grey disc), else the name's initials, as the Home list draws them.
final class HomeRecipientAvatarView: NSView {
    private var text = ""
    private var picture: NSImage?
    private var loading: URL?
    /// The pictures its list has read.
    private let pictures: HomeRecipientPictures

    /// A disc that reads avatar pictures through its list's `pictures`.
    init(pictures: HomeRecipientPictures) {
        self.pictures = pictures
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    nonisolated override var isFlipped: Bool { true }

    /// Shows `avatar`, else the initials of `name`; redraws only when the disc changed.
    func show(_ avatar: HomeChiefAvatar?, name: String) {
        let drawn = (text: text, picture: picture)
        picture = nil
        loading = nil
        switch avatar {
        case .picture(let url):
            text = Self.initials(name)
            load(url)
        case .text(let value):
            text = String(value.prefix(2))
        case nil:
            text = Self.initials(name)
        }
        if text != drawn.text || picture !== drawn.picture { needsDisplay = true }
    }

    /// The picture file is read and downsampled off the main thread, then drawn.
    private func load(_ url: URL) {
        if let cached = pictures.picture(url) {
            picture = cached
            return
        }
        loading = url
        let pictures = pictures
        // task-owner: one read of a small avatar file; a later show() drops its result
        Task { [weak self] in
            let maxPixel = HomeRecipientPictures.maxPixel
            let cgImage = await Task.detached(priority: .userInitiated) {
                CheckedImageSource(blockingContentsOf: url)?.thumbnail(options: [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                    // Decoded here, off the main thread, not at the disc's first draw.
                    kCGImageSourceShouldCacheImmediately: true,
                ])
            }.value
            guard let cgImage else { return }
            let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            pictures.keep(image, for: url)
            guard let self, loading == url, picture !== image else { return }
            needsDisplay = true
            picture = image
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let circle = bounds.insetBy(dx: 0.5, dy: 0.5)
        if let picture {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(ovalIn: circle).addClip()
            picture.draw(in: circle, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
            return
        }
        performWithTheme {
            Palette.hoverFill.setFill()
            NSBezierPath(ovalIn: circle).fill()
            let monogram = text.allSatisfy { $0.isLetter || $0.isNumber }
            let scale: CGFloat = monogram ? (text.count > 1 ? 0.4 : 0.5) : 0.55
            let font = Typography.system(size: circle.height * scale, weight: .semibold)
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Palette.textPrimary]
            let size = text.size(withAttributes: attributes)
            text.draw(at: NSPoint(x: circle.midX - size.width / 2, y: circle.midY - size.height / 2), withAttributes: attributes)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true // invalidate: the theme's fill and text colours changed
    }

    /// One or two letters of `name` (two words: their first letters).
    static func initials(_ name: String) -> String {
        let words = name.split(whereSeparator: { $0.isWhitespace })
        let letters = words.count > 1 ? words.prefix(2).compactMap(\.first).map(String.init).joined() : String(words.first?.prefix(2) ?? "?")
        return letters.uppercased()
    }
}
