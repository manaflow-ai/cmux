import AppKit
import CmuxNextDesign
import UniformTypeIdentifiers

/// The Chief's avatar in the settings card: its picture (or text) in a disc;
/// a click opens the menu that changes it.
@MainActor
final class HomeChiefAvatarButton: NSButton {
    private let size: CGFloat
    /// An emoji face's size against the disc: picture-sized, as the first-run hero draws it
    /// (`HomeFirstRunHero`, 56 on 72). Leo's screenshot (2026-10-20) had a small 🫡 on a large
    /// grey disc beside the header's full-size one.
    static let emojiScale: CGFloat = 0.78

    /// A picture file dropped on the avatar (one PNG, JPEG, HEIC, GIF or WebP, as Choose Picture… offers).
    var onDropPicture: ((URL) -> Void)?

    init(size: CGFloat) {
        self.size = size
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        registerForDraggedTypes([.fileURL])
        isBordered = false
        bezelStyle = .regularSquare
        title = ""
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyUpOrDown
        wantsLayer = true
        layer?.cornerRadius = size / 2
        layer?.masksToBounds = true
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: size), heightAnchor.constraint(equalToConstant: size)])
        font = Typography.system(size: TypeScale.heading, weight: TypeScale.emphasis)
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// The one picture file a drag carries; nil for none, several, or another type.
    private func picture(in drag: any NSDraggingInfo) -> URL? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true,
                                                             .urlReadingContentsConformToTypes: HomeChiefFiles.pictureTypes.map(\.identifier)]
        let files = drag.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
        return files.count == 1 ? files[0] : nil
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let takes = onDropPicture != nil && picture(in: sender) != nil
        highlight(takes)
        return takes ? .copy : []
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        highlight(false)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        highlight(false)
        guard let onDropPicture, let file = picture(in: sender) else { return false }
        onDropPicture(file)
        return true
    }

    /// The picture fills the disc; letters sit centered on the theme's fill, and an emoji (or any
    /// other face that is not letters or digits) fills the disc itself, with no fill behind it.
    func show(picture: NSImage?, text: String?) {
        image = picture
        imagePosition = picture == nil ? .noImage : .imageOnly
        title = picture == nil ? (text ?? "") : ""
        font = showsEmoji ? Typography.system(size: size * Self.emojiScale, weight: .regular)
            : Typography.system(size: TypeScale.heading, weight: TypeScale.emphasis)
        applyTheme()
    }

    /// Text that is not a monogram (an emoji, a flag, a symbol) and so draws picture-sized.
    var showsEmoji: Bool {
        image == nil && !title.isEmpty && !title.allSatisfy { $0.isLetter || $0.isNumber }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyTheme()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
    }

    private func applyTheme() {
        performWithTheme {
            layer?.backgroundColor = image == nil && !showsEmoji ? Palette.hoverFill.cgColor : nil
            contentTintColor = Palette.textPrimary
        }
    }
}

/// A borderless text button drawn as a plain link: the theme's accent (or
/// `ink`), underlined while hovered. Show Traces, Show Memory, Diagnostics.
/// The accent is ``Palette/litGlyph``, never the raw `accent`: a theme that
/// names no accent draws `accent` (its focus ring) at 40% of the text, and
/// Show Traces and Show Memory read as dim grey (Leo's screenshot, 2026-10-20).
@MainActor
final class HomeChiefLinkButton: NSButton {
    /// Nil draws the theme's accent, lifted to read at least as well as secondary text.
    var ink: ThemeInk? { didSet { applyTitle() } }
    var textFont: NSFont = Typography.caption { didSet { applyTitle() } }
    private var text = ""
    private var isHovering = false { didSet { applyTitle() } }
    private var tracking: NSTrackingArea?

    init(title: String, target: AnyObject, action: Selector) {
        super.init(frame: .zero)
        text = title
        self.target = target
        self.action = action
        isBordered = false
        bezelStyle = .regularSquare
        setButtonType(.momentaryChange)
        setAccessibilityLabel(title)
        applyTitle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { isHovering = true }
    override func mouseExited(with event: NSEvent) { isHovering = false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyTitle()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTitle()
    }

    private func applyTitle() {
        let color = performWithTheme { () -> NSColor in
            switch ink {
            case .primary?: Palette.textPrimary
            case .secondary?: Palette.textSecondary
            case .tertiary?: Palette.textTertiary
            case .danger?: Palette.danger
            case nil: Palette.litGlyph
            }
        }
        var attributes: [NSAttributedString.Key: Any] = [.font: textFont, .foregroundColor: color]
        if isHovering { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        attributedTitle = NSAttributedString(string: text, attributes: attributes)
        invalidateIntrinsicContentSize()
    }
}
