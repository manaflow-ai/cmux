public import AppKit

/// A menu's identity card: a large round avatar over a name and a line under it, on a rounded plate inset as the
/// rows' highlight is, as Helium's, Chrome's and Edge's profile menus open (Leo 2026-11-25, of Helium's toolbar
/// profile menu: "yeah even helium has a profile..."). It only shows who the menu is about: it takes no press, and
/// the rows under it act.
///
/// It draws in the menu's light or dark look (`themeRows(in:)` sets the menu's appearance, which the card inherits), in
/// the system's label colors, as AppKit draws the rows around it.
public final class MenuProfileCardView: NSView {
    /// The rows' highlight inset (`MenuMetrics.highlightInset`, CmuxNextDesign), so the plate lines up with a row's
    /// hover highlight.
    static let inset: CGFloat = 5
    static let avatarSide: CGFloat = 44
    static let padding: CGFloat = 12
    static let gap: CGFloat = 8
    static let minimumWidth: CGFloat = 260
    static let plateRadius: CGFloat = 10

    private let avatar = NSImageView()
    private let titleLabel: NSTextField
    private let subtitleLabel: NSTextField?

    /// `image` is drawn at ``avatarSide``: a drawn (vector) avatar keeps its letter in proportion.
    public init(title: String, subtitle: String?, image: NSImage?) {
        titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        titleLabel.textColor = .labelColor
        subtitleLabel = subtitle.map {
            let label = NSTextField(labelWithString: $0)
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            label.textColor = .secondaryLabelColor
            return label
        }
        let lines = titleLabel.intrinsicContentSize.height + (subtitleLabel.map { $0.intrinsicContentSize.height + 2 } ?? 0)
        let height = Self.inset * 2 + Self.padding * 2 + Self.avatarSide + Self.gap + lines
        super.init(frame: NSRect(x: 0, y: 0, width: Self.minimumWidth, height: height))
        // The menu widens the card to its widest row.
        autoresizingMask = .width
        avatar.image = image
        avatar.imageScaling = .scaleProportionallyUpOrDown
        for label in [titleLabel] + (subtitleLabel.map { [$0] } ?? []) {
            label.alignment = .center
            label.lineBreakMode = .byTruncatingTail
            addSubview(label)
        }
        addSubview(avatar)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel([title, subtitle].compactMap(\.self).joined(separator: ", "))
        layoutParts()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError() }

    /// The name the card shows (tests, UI automation).
    public var title: String { titleLabel.stringValue }
    /// The line under the name, when there is one.
    public var subtitle: String? { subtitleLabel?.stringValue }
    /// The avatar it draws.
    public var image: NSImage? { avatar.image }

    public override var isFlipped: Bool { true }

    public override func layout() {
        super.layout()
        layoutParts()
    }

    private func layoutParts() {
        let plate = plateRect
        var y = plate.minY + Self.padding
        avatar.frame = NSRect(x: plate.midX - Self.avatarSide / 2, y: y, width: Self.avatarSide, height: Self.avatarSide)
        y += Self.avatarSide + Self.gap
        let width = plate.width - Self.padding * 2
        let titleHeight = titleLabel.intrinsicContentSize.height
        titleLabel.frame = NSRect(x: plate.minX + Self.padding, y: y, width: width, height: titleHeight)
        y += titleHeight + 2
        if let subtitleLabel {
            subtitleLabel.frame = NSRect(x: plate.minX + Self.padding, y: y, width: width, height: subtitleLabel.intrinsicContentSize.height)
        }
    }

    private var plateRect: NSRect { bounds.insetBy(dx: Self.inset, dy: Self.inset) }

    /// The plate: a tint of the label color, so it reads raised on the menu's material in either look.
    public override func draw(_ dirtyRect: NSRect) {
        NSColor.labelColor.withAlphaComponent(0.07).setFill()
        NSBezierPath(roundedRect: plateRect, xRadius: Self.plateRadius, yRadius: Self.plateRadius).fill()
    }

    /// The press belongs to no row: the card is not a button.
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
