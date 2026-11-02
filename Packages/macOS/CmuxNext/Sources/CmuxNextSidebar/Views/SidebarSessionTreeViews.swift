import AppKit
import CmuxNextDesign
import CmuxNextIcons

/// A row's pull requests (Claude desktop's Code tab): the pull request glyph, and the count when
/// there is more than one. Quiet in the secondary color; only failing checks, the state that needs
/// the person, turn it red (Leo 2026-10-21, "did we remove the pr things by default and also
/// redesign tehm to be better"). Hidden without pull requests. Hovering it opens the pull
/// requests' card (`SidebarPullRequestCard`, `sidebar.pullRequestCard`), which says each one's state.
final class SidebarPullRequestBadgeView: NSView {
    private let glyph = NSImageView()
    private let count = SidebarRowView.label(font: SidebarStyle.subtitleFont)
    private(set) var badge: SidebarPullRequestBadge?
    private var tracking: NSTrackingArea?

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
        // The row was reused or its pull requests changed under an open card: the card follows.
        if pointedAt, hoverCard.isShowing(for: self) {
            if let items = badge?.items, !items.isEmpty { showCard(items) } else { hoverCard.dismiss() }
        }
        if badge == nil { pointedAt = false }
        guard let badge else { return }
        glyph.image = NSImage.icon(.gitPullrequest, size: Self.glyphSize)
        count.setString(String(badge.count))
        count.isHidden = !Self.showsCount(badge)
        tint()
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    /// The badge's color, from the theme: the secondary text color, so a list of rows with pull
    /// requests stays quiet, and the danger color for failing checks, which need the person.
    static func color(_ status: SidebarPullRequestBadge.Status) -> NSColor {
        switch status {
        case .failing: Palette.danger
        case .passing, .attention, .merged: Palette.textSecondary
        }
    }

    /// One pull request is the glyph alone; the count says there are several.
    static func showsCount(_ badge: SidebarPullRequestBadge) -> Bool { badge.count > 1 }

    func tint() {
        guard let badge else { return }
        let color = Self.color(badge.status)
        glyph.contentTintColor = color
        count.setColor(color)
    }

    private static var glyphSize: CGFloat { SidebarStyle.subtitleFont.pointSize }

    // MARK: Hover card (`SidebarPullRequestCard`)

    private var hoverCard: SidebarPullRequestCardController { .shared }
    private var pointedAt = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        guard let items = badge?.items, !items.isEmpty, SidebarPullRequestCardController.isEnabled else { return }
        pointedAt = true
        showCard(items)
    }

    /// In the app's one card window: a workspace card that shows morphs into this one.
    private func showCard(_ items: [SidebarPullRequestItem]) {
        guard let cards = ancestor(SidebarListView.self)?.hoverCard.coordinator else { return }
        let sidebar = ancestor(SidebarView.self)
        hoverCard.badgeEntered(self, items: items, cards: cards) { [weak sidebar] url in sidebar?.model.send(.openUpdateLink(url)) }
    }

    private func ancestor<T: NSView>(_ type: T.Type) -> T? {
        sequence(first: self as NSView, next: \.superview).lazy.compactMap { $0 as? T }.first
    }

    override func mouseExited(with event: NSEvent) {
        guard pointedAt else { return }
        pointedAt = false
        hoverCard.badgeExited()
    }

    override var intrinsicContentSize: NSSize {
        // The count's frame holds its text and padding (`naturalSize`): the text alone clipped it.
        let text = count.naturalSize, height = ceil(max(Self.glyphSize, text.height))
        guard !count.isHidden else { return NSSize(width: ceil(Self.glyphSize), height: height) }
        return NSSize(width: ceil(Self.glyphSize + Metrics.space1 + text.width), height: height)
    }

    override func layout() {
        super.layout()
        let side = Self.glyphSize, text = count.naturalSize
        glyph.frame = NSRect(x: 0, y: (bounds.height - side) / 2, width: side, height: side)
        count.frame = count.isHidden ? .zero
            : NSRect(x: side + Metrics.space1, y: (bounds.height - text.height) / 2, width: ceil(text.width), height: ceil(text.height))
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
