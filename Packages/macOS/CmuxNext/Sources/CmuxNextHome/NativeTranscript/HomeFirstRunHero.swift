import AppKit
import CmuxNextDesign

/// The top of the empty Chief conversation (`HomeFirstRunView`): the Chief's face, large, over two
/// lines that say what the Chief does today: it takes what you want done, does quick things
/// itself, hands longer work to agents in workspaces of their own, and reports back here. Leo
/// 2026-10-19: the old screen did not say what was there. The face is the header's (the
/// profile's picture or text, else 🫡, `HomeChiefAvatar.headerText`), set by the host.
/// `HomeTunables.firstRunHero` (Debug Settings > Home) hides it, for the rows-only panel.
final class HomeFirstRunHero: NSView {
    /// The profile's picture, drawn as the layer's contents.
    let picture = NSView()
    /// The text face when there is no picture: the profile's letters or emoji, else 🫡.
    let glyph = ChromeLabel(labelWithString: "")
    let title = ChromeLabel(labelWithString: HomeStrings.firstRunHeroTitle)
    let body = ChromeLabel(wrappingLabelWithString: HomeStrings.firstRunHeroBody)
    private var scale: CGFloat = 1

    static let pictureSide: CGFloat = 72
    static let glyphSize: CGFloat = 56
    static let titleGap: CGFloat = 6
    static let bodyGap: CGFloat = 4

    override init(frame: NSRect) {
        super.init(frame: frame)
        picture.wantsLayer = true
        picture.layer?.contentsGravity = .resizeAspectFill
        picture.layer?.masksToBounds = true
        picture.setAccessibilityElement(false)
        glyph.font = .systemFont(ofSize: Self.glyphSize)
        glyph.alignment = .center
        glyph.setAccessibilityElement(false)
        title.font = .systemFont(ofSize: TypeScale.Base.title, weight: TypeScale.emphasis)
        title.alignment = .center
        title.lineBreakMode = .byTruncatingTail
        title.setAccessibilityRole(.staticText)
        body.font = .systemFont(ofSize: TypeScale.Base.detail)
        body.alignment = .center
        body.maximumNumberOfLines = 0
        body.setAccessibilityRole(.staticText)
        for view in [picture, glyph, title, body] { addSubview(view) }
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }

    nonisolated override var isFlipped: Bool { true }

    /// The Chief's face: its picture, else its text. Neither draws none (the space stays, so the
    /// panel does not jump).
    func setAvatar(picture image: NSImage?, text: String?) {
        picture.layer?.contents = image
        picture.isHidden = image == nil
        glyph.stringValue = image == nil ? text ?? "" : ""
        glyph.isHidden = image != nil || text == nil
        needsLayout = true
    }

    func applyScale(_ scale: CGFloat) {
        guard self.scale != scale else { return }
        self.scale = scale
        // The face is a picture-sized emoji, not body text: it scales with the picture.
        glyph.font = .systemFont(ofSize: Self.glyphSize * scale)
        title.font = .systemFont(ofSize: TypeScale.Base.title * scale, weight: TypeScale.emphasis)
        body.font = .systemFont(ofSize: TypeScale.Base.detail * scale)
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    func applyColors(primary: NSColor, secondary: NSColor) { // theme-scoped
        glyph.textColor = primary
        title.textColor = primary
        body.textColor = secondary
    }

    /// The hero's height in a column `width` wide: the face, the title and the wrapped body.
    func height(for width: CGFloat) -> CGFloat {
        let side = Self.pictureSide * scale
        let titleHeight = ceil(title.size(forWidth: width).height)
        let bodyHeight = ceil(body.size(forWidth: width).height)
        return side + Self.titleGap * scale + titleHeight + Self.bodyGap * scale + bodyHeight
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        let side = Self.pictureSide * scale
        let face = CGRect(x: (width - side) / 2, y: 0, width: side, height: side)
        picture.frame = face
        picture.layer?.cornerRadius = side / 2
        let glyphHeight = ceil(glyph.intrinsicContentSize.height)
        glyph.frame = CGRect(x: 0, y: face.midY - glyphHeight / 2, width: width, height: glyphHeight)
        let titleHeight = ceil(title.size(forWidth: width).height)
        title.frame = CGRect(x: 0, y: face.maxY + Self.titleGap * scale, width: width, height: titleHeight)
        let bodyHeight = ceil(body.size(forWidth: width).height)
        body.frame = CGRect(x: 0, y: title.frame.maxY + Self.bodyGap * scale, width: width, height: bodyHeight)
    }
}
