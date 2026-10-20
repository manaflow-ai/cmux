import AppKit
import CmuxNextDesign

/// The top of the empty Chief conversation (`HomeFirstRunView`): the Chief's face, the Chief
/// pet's pixel character (`home.chiefPetMascot`, set by the host), over two lines that say what
/// the Chief does today: it takes what you want done, does quick things itself, hands longer
/// work to agents in workspaces of their own, and reports back here. Leo 2026-10-19: the old
/// screen did not say what was there, and its placeholder cat is gone.
/// `HomeTunables.firstRunHero` (Debug Settings > Home) hides it, for the rows-only panel.
final class HomeFirstRunHero: NSView {
    /// The character, drawn as its layer's contents with nearest-neighbour filtering so the
    /// pixel art stays sharp at any scale.
    let picture = NSView()
    let title = ChromeLabel(labelWithString: HomeStrings.firstRunHeroTitle)
    let body = ChromeLabel(wrappingLabelWithString: HomeStrings.firstRunHeroBody)
    private var scale: CGFloat = 1

    static let pictureSide: CGFloat = 72
    static let titleGap: CGFloat = 6
    static let bodyGap: CGFloat = 4

    override init(frame: NSRect) {
        super.init(frame: frame)
        picture.wantsLayer = true
        picture.layer?.contentsGravity = .resizeAspect
        picture.layer?.magnificationFilter = .nearest
        picture.layer?.minificationFilter = .nearest
        picture.setAccessibilityElement(false)
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.alignment = .center
        title.lineBreakMode = .byTruncatingTail
        title.setAccessibilityRole(.staticText)
        body.font = .systemFont(ofSize: 12)
        body.alignment = .center
        body.maximumNumberOfLines = 0
        body.setAccessibilityRole(.staticText)
        for view in [picture, title, body] { addSubview(view) }
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }

    nonisolated override var isFlipped: Bool { true }

    /// The character's art; nil draws none (the space stays, so the panel does not jump).
    var image: NSImage? {
        didSet { picture.layer?.contents = image }
    }

    func applyScale(_ scale: CGFloat) {
        guard self.scale != scale else { return }
        self.scale = scale
        title.font = .systemFont(ofSize: 15 * scale, weight: .semibold)
        body.font = .systemFont(ofSize: 12 * scale)
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    func applyColors(primary: NSColor, secondary: NSColor) { // theme-scoped
        title.textColor = primary
        body.textColor = secondary
    }

    /// The hero's height in a column `width` wide: the picture, the title and the wrapped body.
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
        picture.frame = CGRect(x: (width - side) / 2, y: 0, width: side, height: side)
        let titleHeight = ceil(title.size(forWidth: width).height)
        title.frame = CGRect(x: 0, y: picture.frame.maxY + Self.titleGap * scale, width: width, height: titleHeight)
        let bodyHeight = ceil(body.size(forWidth: width).height)
        body.frame = CGRect(x: 0, y: title.frame.maxY + Self.bodyGap * scale, width: width, height: bodyHeight)
    }
}
