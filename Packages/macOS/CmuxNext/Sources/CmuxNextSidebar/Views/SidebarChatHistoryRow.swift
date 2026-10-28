import AppKit
import CmuxNextDesign

/// A history block's header: its name in the section header's quiet style; Earlier's folds the
/// block on a click, with the disclosure chevron.
final class SidebarChatHistoryHeader: NSView {
    var onClick: (() -> Void)?
    private let name = SidebarRowView.label(font: SidebarStyle.headerFont)
    private let chevron = NSImageView()
    private(set) var foldable = false
    private(set) var folded = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        [name, chevron].forEach(addSubview)
        setAccessibilityElement(true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    var titleText: String { name.stringValue }

    func configure(title: String, foldable: Bool, folded: Bool) {
        (self.foldable, self.folded) = (foldable, folded)
        name.setString(title)
        chevron.isHidden = !foldable
        chevron.image = SidebarStyle.chevron(collapsed: folded)
        setAccessibilityLabel(title)
        setAccessibilityRole(foldable ? .disclosureTriangle : .staticText)
        if foldable { setAccessibilityValue(folded ? 0 : 1) }
        tint()
        needsLayout = true
    }

    func tint() {
        performWithTheme {
            name.setColor(Palette.textTertiary)
            chevron.setTint(Palette.textTertiary)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        tint()
    }

    /// The whole header takes the click (its label and chevron never do).
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) && foldable ? self : nil
    }

    override func accessibilityPerformPress() -> Bool {
        guard foldable, let onClick else { return false }
        onClick()
        return true
    }

    /// Taken here, so the list under it starts no press or marquee.
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard foldable, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick?()
    }

    override func layout() {
        super.layout()
        let side = Metrics.smallIconSize
        chevron.frame = NSRect(x: bounds.width - Metrics.space2 - side, y: (bounds.height - side) / 2, width: side, height: side)
        let h = ceil(name.intrinsicContentSize.height)
        let x = SidebarStyle.titleLeading - SidebarStyle.labelCellPadding
        let trailing = foldable ? chevron.frame.minX - Metrics.space2 : bounds.width - Metrics.space2
        name.frame = NSRect(x: x, y: (bounds.height - h) / 2, width: max(0, trailing - x), height: h)
    }
}

/// One history row: the chat's title and a faint age on the right, compact like a workspace row,
/// with the sidebar's hover fill. No kind icon (Leo 2026-10-15). A click resumes the chat; the
/// right-click menu pins or unpins it.
final class SidebarChatHistoryRow: NSView {
    var onClick: (() -> Void)?
    /// The right-click menu (the app's, from the action registry), built when it opens.
    var makeMenu: (() -> NSMenu?)?
    private let title = SidebarRowView.label(font: SidebarStyle.titleFont)
    private let meta = SidebarRowView.label(font: SidebarStyle.subtitleFont)
    private var quiet = false
    private var tracking: NSTrackingArea?
    private(set) var isHovered = false { didSet { if isHovered != oldValue { tint() } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = SidebarStyle.rowCornerRadius
        title.lineBreakMode = .byTruncatingTail
        [title, meta].forEach(addSubview)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    var titleText: String { title.stringValue }
    var metaText: String? { meta.isHidden ? nil : meta.stringValue }

    func configure(title: String, meta: String?, quiet: Bool) {
        self.title.setString(title)
        self.meta.setString(meta ?? "")
        self.meta.isHidden = meta == nil
        self.quiet = quiet
        setAccessibilityLabel(meta.map { "\(title), \($0)" } ?? title)
        tint()
        needsLayout = true
    }

    func tint() {
        performWithTheme {
            layer?.backgroundColor = isHovered ? Palette.hoverFill.cgColor : nil
            title.setColor(quiet ? Palette.textSecondary : Palette.textPrimary)
            meta.setColor(Palette.textTertiary)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        tint()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { isHovered = false }
    }

    /// The whole row takes the pointer (its labels never do).
    override func hitTest(_ point: NSPoint) -> NSView? {
        !isHidden && frame.contains(point) ? self : nil
    }

    override func accessibilityPerformPress() -> Bool {
        guard let onClick else { return false }
        onClick()
        return true
    }

    /// Taken here, so the list under it starts no press or marquee.
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick?()
    }

    override func menu(for event: NSEvent) -> NSMenu? { contextMenu() }

    /// The row's right-click menu (Pin or Unpin); nil without one or with no rows.
    func contextMenu() -> NSMenu? {
        guard let menu = makeMenu?(), !menu.items.isEmpty else { return nil }
        return menu
    }

    override func layout() {
        super.layout()
        let size = meta.isHidden ? .zero : meta.intrinsicContentSize
        let metaWidth = ceil(size.width)
        // The meta's text ends `space2` from the edge; its frame adds the label's padding around
        // the text (a frame the size of the text alone clipped its last glyph).
        let metaText = NSRect(x: bounds.width - Metrics.space2 - metaWidth, y: (bounds.height - size.height) / 2, width: metaWidth, height: size.height)
        meta.frame = meta.frame(forAlignmentRect: metaText)
        let h = ceil(title.intrinsicContentSize.height)
        let x = SidebarStyle.titleLeading - SidebarStyle.labelCellPadding
        let trailing = meta.isHidden ? bounds.width - Metrics.space2 : metaText.minX - Metrics.space2
        title.frame = NSRect(x: x, y: (bounds.height - h) / 2, width: max(0, trailing - x), height: h)
    }
}
