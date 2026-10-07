import AppKit
import CmuxNextDesign

/// Sizes of the Messages sidebar (measured on macOS 26 Messages, points),
/// scaled with the interface text size.
enum HomeSidebarMetrics {
    static var scale: CGFloat { Typography.userScale }
    static var tileAvatar: CGFloat { 68 * scale }
    static var tileWidth: CGFloat { 98 * scale }
    static var tileHeight: CGFloat { 108 * scale }
    static var rowHeight: CGFloat { 80 * scale }
    static var rowAvatar: CGFloat { 40 * scale }
    static var rowAvatarX: CGFloat { 28 * scale }
    static var rowTextX: CGFloat { 74 * scale }
    static var trailing: CGFloat { 19 * scale }
    static var nameFont: NSFont { .systemFont(ofSize: 13 * scale, weight: .bold) }
    static var bodyFont: NSFont { .systemFont(ofSize: 13 * scale, weight: .regular) }
    static var tileFont: NSFont { .systemFont(ofSize: 11 * scale, weight: .regular) }
    static var tileSelectedFont: NSFont { .systemFont(ofSize: 11 * scale, weight: .semibold) }
}

/// A pinned conversation: a large avatar with its name under it; selected,
/// an accent rounded rect with white text.
final class HomePinnedTileView: NSView {
    let avatar = HomeAvatarView()
    let name = NSTextField(labelWithString: "")
    var isSelected = false { didSet { if isSelected != oldValue { refresh() } } }
    private(set) var item: HomeSidebarItem?
    var onClick: () -> Void = {}

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        addSubview(avatar)
        name.alignment = .center
        name.lineBreakMode = .byTruncatingTail
        addSubview(name)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    func show(_ item: HomeSidebarItem) {
        self.item = item
        avatar.show(item)
        name.stringValue = item.title
        setAccessibilityLabel(item.accessibilityLabel)
        refresh()
    }

    private func refresh() {
        layer?.cornerRadius = 8 * HomeSidebarMetrics.scale
        layer?.backgroundColor = isSelected ? NSColor.controlAccentColor.cgColor : nil
        performWithTheme {
            name.font = isSelected ? HomeSidebarMetrics.tileSelectedFont : HomeSidebarMetrics.tileFont
            name.textColor = isSelected ? .white : Palette.textSecondary
        }
        setAccessibilitySelected(isSelected)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh()
    }

    override func layout() {
        super.layout()
        let side = HomeSidebarMetrics.tileAvatar
        avatar.frame = NSRect(x: (bounds.width - side) / 2, y: 10 * HomeSidebarMetrics.scale, width: side, height: side)
        let height = ceil(name.intrinsicContentSize.height)
        name.frame = NSRect(x: 4, y: avatar.frame.maxY + 6 * HomeSidebarMetrics.scale, width: bounds.width - 8, height: height)
    }

    override func mouseDown(with event: NSEvent) { onClick() }
    override func accessibilityPerformPress() -> Bool { onClick(); return true }
}

/// A conversation row: avatar, bold name, the time at the right, a two-line
/// gray preview (a reply marked with an arrow), an unread dot at the left
/// and an inset separator under it.
final class HomeSidebarRowView: NSView {
    let avatar = HomeAvatarView()
    let name = NSTextField(labelWithString: "")
    let time = NSTextField(labelWithString: "")
    let preview = NSTextField(wrappingLabelWithString: "")
    let dot = NSView()
    let separator = NSView()
    var isSelected = false { didSet { if isSelected != oldValue { refresh() } } }
    var showsSeparator = true { didSet { separator.isHidden = !showsSeparator } }
    private(set) var item: HomeSidebarItem?
    var onClick: () -> Void = {}

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for view in [avatar, name, time, preview, dot, separator] as [NSView] { addSubview(view) }
        name.lineBreakMode = .byTruncatingTail
        preview.maximumNumberOfLines = 2
        preview.lineBreakMode = .byTruncatingTail
        preview.cell?.truncatesLastVisibleLine = true
        dot.wantsLayer = true
        separator.wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    func show(_ item: HomeSidebarItem) {
        self.item = item
        avatar.show(item)
        name.stringValue = item.title
        time.stringValue = item.time
        preview.stringValue = (item.isReply ? "↩︎ " : "") + item.preview
        dot.isHidden = !item.unread
        setAccessibilityLabel(item.accessibilityLabel)
        refresh()
        needsLayout = true
    }

    private func refresh() {
        layer?.cornerRadius = 8 * HomeSidebarMetrics.scale
        layer?.backgroundColor = isSelected ? NSColor.controlAccentColor.cgColor : nil
        performWithTheme {
            name.font = HomeSidebarMetrics.nameFont
            name.textColor = isSelected ? .white : Palette.textPrimary
            time.font = HomeSidebarMetrics.bodyFont
            time.textColor = isSelected ? .white : Palette.textSecondary
            preview.font = HomeSidebarMetrics.bodyFont
            preview.textColor = isSelected ? NSColor.white.withAlphaComponent(0.85) : Palette.textSecondary
            dot.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
            separator.layer?.backgroundColor = Palette.separator.cgColor
        }
        setAccessibilitySelected(isSelected)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh()
    }

    override func layout() {
        super.layout()
        let m = HomeSidebarMetrics.self
        let top = 12 * m.scale
        avatar.frame = NSRect(x: m.rowAvatarX, y: (bounds.height - m.rowAvatar) / 2, width: m.rowAvatar, height: m.rowAvatar)
        let lineHeight = ceil(name.intrinsicContentSize.height)
        let timeWidth = ceil(time.intrinsicContentSize.width)
        let right = bounds.width - m.trailing
        time.frame = NSRect(x: right - timeWidth, y: top, width: timeWidth, height: lineHeight)
        name.frame = NSRect(x: m.rowTextX, y: top, width: max(0, time.frame.minX - 8 - m.rowTextX), height: lineHeight)
        let width = max(0, right - m.rowTextX)
        preview.preferredMaxLayoutWidth = width
        let previewHeight = min(ceil(preview.intrinsicContentSize.height), ceil(m.bodyFont.boundingRectForFont.height * 2) + 2)
        preview.frame = NSRect(x: m.rowTextX, y: name.frame.maxY + 1, width: width, height: previewHeight)
        let size = 10 * m.scale
        dot.frame = NSRect(x: (m.rowAvatarX - size) / 2, y: avatar.frame.midY - size / 2, width: size, height: size)
        dot.layer?.cornerRadius = size / 2
        separator.frame = NSRect(x: m.rowTextX, y: bounds.height - 1, width: width, height: 1 / max(1, window?.backingScaleFactor ?? 2))
    }

    override func mouseDown(with event: NSEvent) { onClick() }
    override func accessibilityPerformPress() -> Bool { onClick(); return true }
}
