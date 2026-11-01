public import AppKit
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
    /// When the recipient was last active ("Active 2 hours ago"); the list shows it only on rows that
    /// would otherwise read the same as another (two Chiefs named "Chief" on this Mac).
    public var activity: String?

    /// - Parameters:
    ///   - avatar: The Chief's avatar; nil draws initials.
    ///   - tag: Where a Chief runs; nil shows the source alone.
    ///   - activity: When it was last active, shown only to tell alike rows apart.
    public init(avatar: HomeChiefAvatar? = nil, tag: String? = nil, activity: String? = nil) {
        self.avatar = avatar
        self.tag = tag
        self.activity = activity
    }
}

/// A suggestion row's avatar disc: the Chief's picture or text avatar (an
/// emoji on the grey disc), else the name's initials, as the Home list draws them.
final class HomeRecipientAvatarView: NSView {
    private var text = ""
    private var picture: NSImage?
    private var loading: URL?
    /// Pictures already read, by file: the list rebuilds its rows on every keystroke.
    /// Each New Message list starts empty (``forgetPictures()``), so a changed picture shows.
    private static var pictures: [URL: NSImage] = [:]

    static func forgetPictures() { pictures = [:] }

    nonisolated override var isFlipped: Bool { true }

    /// Shows `avatar`, else the initials of `name`.
    func show(_ avatar: HomeChiefAvatar?, name: String) {
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
        needsDisplay = true
    }

    /// The picture file is read off the main thread, then drawn.
    private func load(_ url: URL) {
        if let cached = Self.pictures[url] {
            picture = cached
            return
        }
        loading = url
        // task-owner: one read of a small avatar file; a later show() drops its result
        Task { [weak self] in
            // Read and decoded off the main thread (an uploaded avatar is a 512 px PNG).
            let decoded = await Task.detached(priority: .userInitiated) { () -> CGImage? in
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
                return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
            }.value
            guard let decoded else { return }
            let image = NSImage(cgImage: decoded, size: .zero)
            Self.pictures[url] = image
            guard let self, loading == url else { return }
            picture = image
            needsDisplay = true
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
        needsDisplay = true
    }

    /// One or two letters of `name` (two words: their first letters).
    static func initials(_ name: String) -> String {
        let words = name.split(whereSeparator: { $0.isWhitespace })
        let letters = words.count > 1 ? words.prefix(2).compactMap(\.first).map(String.init).joined() : String(words.first?.prefix(2) ?? "?")
        return letters.uppercased()
    }
}
