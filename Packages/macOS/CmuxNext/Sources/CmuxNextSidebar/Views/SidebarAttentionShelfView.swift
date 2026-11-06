import AppKit
import CmuxNextDesign

/// The notification surfaces that float over the list (`SidebarNotificationEmphasis`): the inbox shelf
/// pinned at the top of the sidebar and the arrival card at its bottom. Both list workspaces with
/// something for the person, each a line with its kind's glyph, its name and why (New, Approve,
/// Question, Failed), and take a click to that workspace. They float over the list, so a row never
/// moves when one grows; the list's scroll range grows by its height instead. Hidden while empty.
final class SidebarAttentionShelfView: NSView {
    enum Role { case inbox, arrival }

    let role: Role
    static var shownItems: Int { 4 }
    /// Opens a workspace: a line, or the first one the shelf had no room for.
    var onOpen: ((WorkspaceID) -> Void)?
    /// The arrival card's ×.
    var onDismiss: (() -> Void)?
    private(set) var items: [SidebarAttentionItem] = []
    private let header = SidebarRowView.label(font: SidebarStyle.headerFont)
    private let count = SidebarRowView.label(font: SidebarStyle.badgeFont)
    private let countFill = CALayer()
    /// An opaque sidebar-colored base under the tint: the shelf floats over rows, which must not show through.
    private let backing = CALayer(), tintFill = CALayer(), accent = CALayer()
    private let footnote = AttentionLine()
    private let lines = (0..<4).map { _ in AttentionLine() }
    private lazy var dismiss: SidebarIconButton = {
        let button = SidebarIconButton(symbol: "xmark", label: Strings.dismissCard)
        button.onPress = { [weak self] in self?.onDismiss?() }
        return button
    }()

    init(role: Role) {
        self.role = role
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Metrics.surfaceCornerRadius
        layer?.masksToBounds = true
        [backing, tintFill, accent, countFill].forEach { layer?.addSublayer($0) }
        ([header, count] as [NSView]).forEach(addSubview)
        (lines + [footnote]).forEach(addSubview)
        if role == .arrival { addSubview(dismiss) }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        isHidden = true
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    /// The height the shelf takes over the list; 0 while it is empty.
    var preferredHeight: CGFloat {
        guard !items.isEmpty else { return 0 }
        let shown = CGFloat(min(items.count, Self.shownItems))
        return Self.pad + Self.headerHeight + shown * Self.lineHeight + (items.count > Self.shownItems ? Self.footHeight : 0) + Self.pad
    }

    /// The most urgent kind in the shelf: its color.
    var urgent: WorkspaceRowAttention.Kind? { items.map(\.attention.kind).min() }

    func show(_ items: [SidebarAttentionItem]) {
        guard items != self.items else { return }
        // The inbox lists the most urgent first; the arrival card keeps its newest-first queue.
        self.items = role == .inbox ? items.enumerated().sorted { a, b in
            a.element.attention.kind != b.element.attention.kind ? a.element.attention.kind < b.element.attention.kind : a.offset < b.offset
        }.map(\.element) : items
        isHidden = items.isEmpty
        header.setString(role == .inbox ? Strings.needsYou : Strings.attentionArrived)
        count.setString(String(items.count))
        for (n, line) in lines.enumerated() {
            let item = n < self.items.count ? self.items[n] : nil
            line.isHidden = item == nil
            guard let item else { continue }
            line.configure(item)
            line.onClick = { [weak self] in self?.onOpen?(item.id) }
        }
        let more = self.items.count - Self.shownItems
        footnote.isHidden = more <= 0
        if more > 0 {
            footnote.configureQuiet(Strings.needsYouMore(more))
            let next = self.items[Self.shownItems].id
            footnote.onClick = { [weak self] in self?.onOpen?(next) }
        }
        setAccessibilityLabel([role == .inbox ? Strings.needsYou : Strings.attentionArrived, String(items.count)].joined(separator: ", "))
        tint()
        needsLayout = true
    }

    func tint() {
        performWithTheme {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let color = urgent.map(Self.color) ?? Palette.statusUnread
            backing.backgroundColor = (Palette.sidebarBackground.usingColorSpace(.sRGB) ?? Palette.windowBackground).withAlphaComponent(1).cgColor
            tintFill.backgroundColor = color.withAlphaComponent(role == .arrival ? 0.16 : 0.1).cgColor
            accent.backgroundColor = color.cgColor
            layer?.borderColor = color.withAlphaComponent(0.55).cgColor
            layer?.borderWidth = Metrics.lineWidth(1.5)
            header.setColor(color)
            countFill.backgroundColor = color.cgColor
            count.setColor(.white)
            (lines + [footnote]).forEach { $0.tint() }
            CATransaction.commit()
        }
    }

    @MainActor static func color(_ kind: WorkspaceRowAttention.Kind) -> NSColor {
        switch kind {
        case .unread: Palette.statusUnread
        case .needsYou: Palette.statusAttention
        case .failed: Palette.statusError
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        tint()
    }

    private static var pad: CGFloat { Metrics.space2 }
    private static var headerHeight: CGFloat { SidebarDensityTokens.rowHeight }
    static var lineHeight: CGFloat { SidebarDensityTokens.rowHeight + Metrics.space1 }
    private static var footHeight: CGFloat { ceil(SidebarStyle.subtitleFont.pointSize + Metrics.space2) }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        (backing.frame, tintFill.frame) = (bounds, bounds)
        // A 3 pt band of the urgent color along the shelf's leading edge.
        accent.frame = CGRect(x: 0, y: 0, width: 3, height: bounds.height)
        let inset = SidebarStyle.horizontalInset, width = bounds.width - 2 * inset
        var y = Self.pad
        let h = header.naturalSize.height
        header.frame = NSRect(x: inset, y: y + (Self.headerHeight - h) / 2, width: ceil(header.naturalSize.width), height: h)
        let c = count.naturalSize
        let chip = NSRect(x: header.frame.maxX + Metrics.space2, y: y + (Self.headerHeight - c.height - 2) / 2,
                          width: max(c.height + 2, ceil(c.width) + 2 * Metrics.space2), height: c.height + 2)
        countFill.frame = chip
        countFill.cornerRadius = chip.height / 2
        count.frame = NSRect(x: chip.midX - ceil(c.width) / 2, y: chip.minY + 1, width: ceil(c.width), height: c.height)
        if role == .arrival {
            let side = SidebarStyle.controlSize
            dismiss.frame = NSRect(x: bounds.width - inset / 2 - side, y: y + (Self.headerHeight - side) / 2, width: side, height: side)
        }
        y += Self.headerHeight
        for line in lines where !line.isHidden {
            line.frame = NSRect(x: inset / 2, y: y, width: width + inset, height: Self.lineHeight)
            y += Self.lineHeight
        }
        footnote.frame = NSRect(x: inset / 2, y: y, width: width + inset, height: Self.footHeight)
    }
}

/// One shelf line: the kind's dot, the workspace's name, and why on the right in the kind's color.
private final class AttentionLine: NSView {
    var onClick: (() -> Void)?
    private let glyph = CALayer()
    private let title = SidebarRowView.label(font: SidebarStyle.titleFont)
    private let reason = SidebarRowView.label(font: SidebarStyle.subtitleFont)
    private var kind: WorkspaceRowAttention.Kind?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = Metrics.insetCornerRadius
        layer?.addSublayer(glyph)
        [title, reason].forEach(addSubview)
        title.lineBreakMode = .byTruncatingTail
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    func configure(_ item: SidebarAttentionItem) {
        kind = item.attention.kind
        title.setString(item.title)
        reason.setString(Strings.attentionReason(item.attention))
        title.font = NSFont.systemFont(ofSize: SidebarStyle.titleFont.pointSize, weight: TypeScale.emphasis)
        glyph.isHidden = false
        setAccessibilityLabel([item.title, Strings.attentionReason(item.attention)].joined(separator: ", "))
        tint()
        needsLayout = true
    }

    func configureQuiet(_ text: String) {
        kind = nil
        title.setString(text)
        reason.setString("")
        title.font = SidebarStyle.subtitleFont
        glyph.isHidden = true
        setAccessibilityLabel(text)
        tint()
        needsLayout = true
    }

    func tint() {
        performWithTheme {
            let color = kind.map(SidebarAttentionShelfView.color) ?? Palette.textTertiary
            glyph.backgroundColor = color.cgColor
            title.setColor(kind == nil ? Palette.textTertiary : Palette.textPrimary)
            reason.setColor(color)
        }
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
        guard onClick != nil else { return }
        layer?.backgroundColor = performWithTheme { Palette.badgeFill }.cgColor
    }

    override func mouseUp(with event: NSEvent) {
        layer?.backgroundColor = nil
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    override func layout() {
        super.layout()
        let inset = SidebarStyle.horizontalInset / 2, side = SidebarStyle.statusDotSize
        glyph.frame = CGRect(x: inset, y: (bounds.height - side) / 2, width: side, height: side)
        glyph.cornerRadius = side / 2
        let textX = glyph.isHidden ? inset : glyph.frame.maxX + Metrics.space2
        let r = reason.naturalSize
        reason.frame = NSRect(x: bounds.width - inset - ceil(r.width), y: (bounds.height - r.height) / 2, width: ceil(r.width), height: r.height)
        let t = title.naturalSize
        title.frame = NSRect(x: textX, y: (bounds.height - t.height) / 2,
                             width: max(0, (reason.stringValue.isEmpty ? bounds.width - inset : reason.frame.minX - Metrics.space2) - textX), height: t.height)
    }
}
