import AppKit
import CmuxNextDesign
import CmuxNextIcons

/// A row's pull requests in the session tree (Claude desktop's Code tab): the pull request glyph
/// and the count, both in the status color (green open and passing, orange a draft, a conflict or
/// a failed check, purple merged). Hidden without pull requests.
final class SidebarPullRequestBadgeView: NSView {
    private let glyph = NSImageView()
    private let count = SidebarRowView.label(font: SidebarStyle.subtitleFont)
    private(set) var badge: SidebarPullRequestBadge?

    override init(frame: NSRect) {
        super.init(frame: frame)
        glyph.imageScaling = .scaleProportionallyDown
        count.font = SidebarStyle.badgeFont
        [glyph, count].forEach(addSubview)
        setAccessibilityElement(false) // the row's label says it (`Strings.pullRequests`)
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ badge: SidebarPullRequestBadge?) {
        self.badge = badge
        isHidden = badge == nil
        guard let badge else { return }
        glyph.image = NSImage.icon(.gitPullrequest, size: Self.glyphSize)
        count.setString(String(badge.count))
        tint()
        needsLayout = true
    }

    /// The status color, from the theme: success, attention, and the theme's purple.
    static func color(_ status: SidebarPullRequestBadge.Status) -> NSColor {
        switch status {
        case .passing: Palette.success
        case .attention: Palette.attention
        case .merged: GroupColor.purple.markColor
        }
    }

    func tint() {
        guard let badge else { return }
        let color = Self.color(badge.status)
        glyph.contentTintColor = color
        count.setColor(color)
    }

    private static var glyphSize: CGFloat { SidebarStyle.subtitleFont.pointSize }

    override var intrinsicContentSize: NSSize {
        let text = count.intrinsicContentSize
        return NSSize(width: ceil(Self.glyphSize + Metrics.space1 + text.width), height: ceil(max(Self.glyphSize, text.height)))
    }

    override func layout() {
        super.layout()
        let side = Self.glyphSize, text = count.intrinsicContentSize
        glyph.frame = NSRect(x: 0, y: (bounds.height - side) / 2, width: side, height: side)
        count.frame = NSRect(x: side + Metrics.space1, y: (bounds.height - text.height) / 2, width: ceil(text.width), height: ceil(text.height))
    }
}

/// The Command-number of one of the first rows in the session tree: its digit in a small keycap,
/// quiet like the shortcut hints. Hidden without a digit.
final class SidebarKeycapView: NSView {
    private let digit = SidebarRowView.label(font: SidebarStyle.badgeFont)
    private(set) var number: Int?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        digit.alignment = .center
        addSubview(digit)
        setAccessibilityElement(false) // Command-number is announced by the shortcut, not the row
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ number: Int?) {
        self.number = number
        digit.setString(number.map(String.init) ?? "")
        needsLayout = true
    }

    func tint() {
        digit.setColor(Palette.textTertiary)
        layer?.borderColor = Palette.separator.cgColor
        layer?.borderWidth = Metrics.lineWidth(1)
        layer?.cornerRadius = Metrics.space1
    }

    override var intrinsicContentSize: NSSize {
        let side = ceil(SidebarStyle.badgeFont.pointSize + Metrics.space2)
        return NSSize(width: side, height: side)
    }

    override func layout() {
        super.layout()
        let text = digit.intrinsicContentSize
        digit.frame = NSRect(x: 0, y: (bounds.height - text.height) / 2, width: bounds.width, height: ceil(text.height))
    }
}
