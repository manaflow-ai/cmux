import AppKit
import CmuxNextDesign

/// The session tree's needs-you tray (`SidebarNeedsYou`): docked at the bottom of the list, over it,
/// so a row never moves when the tray grows or shrinks (the list's scroll range grows by its height
/// instead). A header with the count, up to three sessions blocked on you (a glyph, the title, why,
/// and the path to it under), and a quiet line for the rest and for finished unread sessions.
/// Clicking an item goes to its row, opening the folds above it. Hidden while nothing needs you.
final class SidebarNeedsYouTrayView: NSView {
    static let shownItems = 3
    /// Goes to a session: an item, or the first finished unread one.
    var onOpen: ((WorkspaceID) -> Void)?
    private(set) var tray = SidebarNeedsYou()
    private let header = SidebarRowView.label(font: SidebarStyle.headerFont)
    private let count = SidebarRowView.label(font: SidebarStyle.badgeFont)
    private let countFill = CALayer()
    /// An opaque sidebar-colored base under the tint: the tray floats over rows, which must not show through.
    private let backing = CALayer(), tintFill = CALayer()
    private let footnote = TrayLine()
    private let rows = (0..<SidebarNeedsYouTrayView.shownItems).map { _ in TrayLine() }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = Metrics.space3
        layer?.masksToBounds = true
        layer?.addSublayer(backing)
        layer?.addSublayer(tintFill)
        layer?.addSublayer(countFill)
        ([header, count] as [NSView]).forEach(addSubview)
        (rows + [footnote]).forEach(addSubview)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    /// The height the tray takes at the bottom of the list; 0 while nothing needs you.
    var preferredHeight: CGFloat {
        guard !tray.isEmpty else { return 0 }
        let shown = CGFloat(min(tray.items.count, Self.shownItems))
        return Self.pad + Self.headerHeight + shown * Self.itemHeight + (footnoteText == nil ? 0 : Self.lineHeight) + Self.pad
    }

    func show(_ tray: SidebarNeedsYou) {
        guard tray != self.tray else { return }
        self.tray = tray
        isHidden = tray.isEmpty
        header.setString(Strings.needsYou)
        count.setString(String(tray.items.count))
        count.isHidden = tray.items.isEmpty
        countFill.isHidden = tray.items.isEmpty
        for (n, row) in rows.enumerated() {
            let item = n < tray.items.count ? tray.items[n] : nil
            row.isHidden = item == nil
            guard let item else { continue }
            row.configure(title: item.title, reason: Strings.needsYouReason(item), detail: item.path.joined(separator: " › "),
                          failed: item.reason == .failed)
            row.onClick = { [weak self] in self?.onOpen?(item.id) }
            row.setAccessibilityLabel([item.title, Strings.needsYouReason(item), item.path.joined(separator: ", ")]
                .filter { !$0.isEmpty }.joined(separator: ", "))
        }
        footnote.isHidden = footnoteText == nil
        footnote.configure(title: footnoteText ?? "", reason: "", detail: "", failed: false, quiet: true)
        footnote.setAccessibilityLabel(footnoteText)
        // The line goes to the first session the tray has no room for, else to the first finished unread one.
        let next = tray.items.count > Self.shownItems ? tray.items[Self.shownItems].id : tray.firstUnread
        footnote.onClick = next.map { first in { [weak self] in self?.onOpen?(first) } }
        setAccessibilityLabel(Strings.needsYouSummary(blocked: tray.items.count, unread: tray.unread))
        tint()
        needsLayout = true
    }

    /// "+2 more · 7 finished, unread", or either half alone.
    private var footnoteText: String? {
        let more = tray.items.count - Self.shownItems
        let parts = [more > 0 ? Strings.needsYouMore(more) : nil, tray.unread > 0 ? Strings.needsYouUnread(tray.unread) : nil]
        let text = parts.compactMap { $0 }.joined(separator: " · ")
        return text.isEmpty ? nil : text
    }

    func tint() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let blocked = !tray.items.isEmpty
        backing.backgroundColor = (Palette.sidebarBackground.usingColorSpace(.sRGB) ?? Palette.windowBackground).withAlphaComponent(1).cgColor
        layer?.backgroundColor = nil
        tintFill.backgroundColor = (blocked ? Palette.attention.withAlphaComponent(0.08) : Palette.badgeFill).cgColor
        layer?.borderColor = (blocked ? Palette.attention.withAlphaComponent(0.4) : Palette.separator).cgColor
        layer?.borderWidth = Metrics.lineWidth(1)
        header.setColor(blocked ? Palette.attention : Palette.textSecondary)
        countFill.backgroundColor = Palette.attention.cgColor
        count.setColor(Palette.textOnPrimary)
        (rows + [footnote]).forEach { $0.tint() }
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        tint()
    }

    private static var pad: CGFloat { Metrics.space2 }
    private static var headerHeight: CGFloat { SidebarDensityTokens.rowHeight }
    private static var lineHeight: CGFloat { ceil(SidebarStyle.subtitleFont.pointSize + Metrics.space2) }
    private static var itemHeight: CGFloat { SidebarDensityTokens.rowHeight + lineHeight - Metrics.space1 }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        (backing.frame, tintFill.frame) = (bounds, bounds)
        let inset = SidebarStyle.horizontalInset, width = bounds.width - 2 * inset
        var y = Self.pad
        let h = header.naturalSize.height
        header.frame = NSRect(x: inset, y: y + (Self.headerHeight - h) / 2, width: ceil(header.naturalSize.width), height: h)
        let c = count.naturalSize
        let chip = NSRect(x: header.frame.maxX + Metrics.space2, y: y + (Self.headerHeight - c.height - 2) / 2,
                          width: ceil(c.width) + 2 * Metrics.space2, height: c.height + 2)
        countFill.frame = chip
        countFill.cornerRadius = Metrics.chipCornerRadius(height: chip.height)
        count.frame = NSRect(x: chip.minX + Metrics.space2, y: chip.minY + 1, width: ceil(c.width), height: c.height)
        y += Self.headerHeight
        for row in rows where !row.isHidden {
            row.frame = NSRect(x: inset / 2, y: y, width: width + inset, height: Self.itemHeight)
            y += Self.itemHeight
        }
        footnote.frame = NSRect(x: inset / 2, y: y, width: width + inset, height: Self.lineHeight)
    }
}

/// One line of the tray: a glyph, the title, why it waits on the right, and a dim second line.
private final class TrayLine: NSView {
    var onClick: (() -> Void)?
    private let glyph = CALayer()
    private let title = SidebarRowView.label(font: SidebarStyle.titleFont)
    private let reason = SidebarRowView.label(font: SidebarStyle.subtitleFont)
    private let detail = SidebarRowView.label(font: SidebarStyle.subtitleFont)
    private var failed = false, quiet = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = Metrics.space2
        layer?.addSublayer(glyph)
        [title, reason, detail].forEach(addSubview)
        title.lineBreakMode = .byTruncatingTail
        detail.lineBreakMode = .byTruncatingTail
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    func configure(title: String, reason: String, detail: String, failed: Bool, quiet: Bool = false) {
        self.title.setString(title)
        self.reason.setString(reason)
        self.detail.setString(detail)
        self.detail.isHidden = detail.isEmpty
        (self.failed, self.quiet) = (failed, quiet)
        glyph.isHidden = quiet
        self.title.font = quiet ? SidebarStyle.subtitleFont : SidebarStyle.titleFont
        tint()
        needsLayout = true
    }

    func tint() {
        let color = failed ? Palette.danger : Palette.attention
        glyph.backgroundColor = color.cgColor
        title.setColor(quiet ? Palette.textTertiary : Palette.textPrimary)
        reason.setColor(color)
        detail.setColor(Palette.textTertiary)
    }

    /// The whole line takes the click, its labels too (`point` is in the superview's coordinates).
    override func hitTest(_ point: NSPoint) -> NSView? {
        !isHidden && frame.contains(point) ? self : nil
    }

    override func accessibilityPerformPress() -> Bool {
        guard let onClick else { return false }
        onClick()
        return true
    }

    override func mouseDown(with event: NSEvent) {
        guard onClick != nil else { return } // a footnote with nowhere to go does not press
        layer?.backgroundColor = Palette.badgeFill.cgColor
    }

    override func mouseUp(with event: NSEvent) {
        layer?.backgroundColor = nil
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    override func layout() {
        super.layout()
        let inset = SidebarStyle.horizontalInset / 2
        let side = SidebarStyle.dotSize
        let firstLine = quiet ? bounds.height : SidebarDensityTokens.rowHeight
        glyph.frame = CGRect(x: inset, y: (firstLine - side) / 2, width: side, height: side)
        glyph.cornerRadius = failed ? 1 : side / 2
        let textX = quiet ? inset : glyph.frame.maxX + Metrics.space2
        let r = reason.naturalSize
        reason.frame = NSRect(x: bounds.width - inset - ceil(r.width), y: (firstLine - r.height) / 2, width: ceil(r.width), height: r.height)
        let t = title.naturalSize
        title.frame = NSRect(x: textX, y: (firstLine - t.height) / 2, width: max(0, reason.frame.minX - Metrics.space2 - textX), height: t.height)
        let d = detail.naturalSize
        detail.frame = NSRect(x: textX, y: firstLine - Metrics.space1, width: max(0, bounds.width - inset - textX), height: d.height)
    }
}
