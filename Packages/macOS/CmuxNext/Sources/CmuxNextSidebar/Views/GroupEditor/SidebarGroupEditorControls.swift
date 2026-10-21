import AppKit
import CmuxNextDesign
import CmuxNextIcons
import QuartzCore

/// One color dot in the group editor: the group palette's swatch, or for
/// none (grey) the grey swatch with a hairline edge. The chosen dot gets a
/// ring in the primary text color.
final class SidebarGroupSwatchView: NSView {
    let color: GroupColor
    var isChosen = false { didSet { if oldValue != isChosen { updateColors() } } }
    var onPick: ((GroupColor) -> Void)?
    private let fill = CALayer()
    private let ring = CALayer()
    private var isHovered = false { didSet { if oldValue != isHovered { updateColors() } } }

    init(color: GroupColor) {
        self.color = color
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        ring.borderWidth = Metrics.space1 * 0.75
        for sublayer in [ring, fill] {
            sublayer.actions = ["bounds": NSNull(), "position": NSNull(), "cornerRadius": NSNull(), "backgroundColor": NSNull(), "borderColor": NSNull()]
            layer?.addSublayer(sublayer)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(GroupEditorStrings.colorName(color))
        setAccessibilityIdentifier("cmux.sidebar.groupEditor.color.\(color.rawValue)")
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize {
        let side = Metrics.iconSize + Metrics.space2
        return NSSize(width: side, height: side)
    }

    override func layout() {
        super.layout()
        let side = min(bounds.width, bounds.height)
        let outer = CGRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side)
        ring.frame = outer
        ring.cornerRadius = side / 2
        let inner = outer.insetBy(dx: Metrics.space1 + 1, dy: Metrics.space1 + 1)
        fill.frame = inner
        fill.cornerRadius = inner.width / 2
        updateColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        performWithTheme {
            // The group's swatch, as its members' line draws it; none draws an edge too.
            fill.backgroundColor = GroupTint.palette(color).lineColor(themed: SidebarGroupPalette.tunable.value == .theme).cgColor
            fill.borderColor = Palette.textTertiary.cgColor
            fill.borderWidth = color == .grey ? Metrics.dividerThickness : 0
            ring.borderColor = (isChosen ? Palette.textPrimary : (isHovered ? Palette.separator : NSColor.clear)).cgColor
        }
        setAccessibilityValue(isChosen ? 1 : 0)
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onPick?(color) }
    }

    override func accessibilityPerformPress() -> Bool {
        onPick?(color)
        return true
    }
}

/// A menu-like row of the group editor: an icon, the title and the
/// action's shortcut, like a menu item.
final class SidebarGroupEditorRow: NSView {
    var onPress: (() -> Void)?
    let item: SidebarGroupEditorItem
    private let icon = DecorativeImageView() // the row's label names the action
    private let label = ChromeLabel(labelWithString: "")
    private let shortcut = ChromeLabel(labelWithString: "")
    private var isHovered = false { didSet { if oldValue != isHovered { updateColors(animated: window != nil) } } }

    init(_ item: SidebarGroupEditorItem) {
        self.item = item
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Metrics.itemCornerRadius
        layer?.cornerCurve = .continuous
        label.font = Typography.body
        label.stringValue = item.title
        label.lineBreakMode = .byTruncatingTail
        shortcut.font = Typography.body
        shortcut.stringValue = item.shortcut ?? ""
        shortcut.alignment = .right
        icon.image = item.icon.map { NSImage.icon($0, size: .iconRowSize(forLabelPointSize: Typography.body.pointSize)) }
        for view in [icon, label, shortcut] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Metrics.sidebarRowHeight),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.space3),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: Metrics.iconSize),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: Metrics.space3),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            shortcut.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: Metrics.space4),
            shortcut.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.space3),
            shortcut.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(item.title)
        setAccessibilityIdentifier("cmux.sidebar.groupEditor.action.\(item.id)")
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
        updateColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors(animated: Bool = false) {
        performWithTheme {
            if let layer { ChromeHover.paint(layer, isHovered ? Palette.hoverFill : nil, animated: animated) }
            label.textColor = Palette.textPrimary
            icon.contentTintColor = Palette.textSecondary
            shortcut.textColor = Palette.textTertiary
        }
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onPress?() }
    }

    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return true
    }
}

/// The group editor's and the group chip's strings (Resources/Localizable.xcstrings, en and ja).
/// Rows the group's right-click menu also offers use its words (Close All in Group, Ungroup, Move to
/// New Window: CmuxNextActions ObjectMenuLabels).
enum GroupEditorStrings {
    static var editor: String { String(localized: "sidebar.groupEditor.ax", defaultValue: "Edit Workspace Group", bundle: .module) }
    static var nameLabel: String { String(localized: "sidebar.groupEditor.name", defaultValue: "Group name", bundle: .module) }
    static var namePlaceholder: String { String(localized: "sidebar.groupEditor.namePlaceholder", defaultValue: "Name this group", bundle: .module) }
    static var newWorkspace: String { String(localized: "sidebar.groupEditor.newWorkspace", defaultValue: "New Workspace in Group", bundle: .module) }
    static var moveToNewWindow: String { String(localized: "sidebar.groupEditor.moveToNewWindow", defaultValue: "Move to New Window", bundle: .module) }
    static var close: String { String(localized: "sidebar.groupEditor.closeAll", defaultValue: "Close All in Group", bundle: .module) }
    static var ungroup: String { String(localized: "sidebar.groupEditor.ungroup", defaultValue: "Ungroup", bundle: .module) }
    static var delete: String { String(localized: "sidebar.groupEditor.delete", defaultValue: "Delete Group", bundle: .module) }
    static var pin: String { String(localized: "sidebar.groupEditor.pin", defaultValue: "Pin Group", bundle: .module) }
    static var unpin: String { String(localized: "sidebar.groupEditor.unpin", defaultValue: "Unpin Group", bundle: .module) }
    static var moveToTop: String { String(localized: "sidebar.groupEditor.moveToTop", defaultValue: "Move to Top", bundle: .module) }
    static var moreActions: String { String(localized: "sidebar.groupEditor.moreActions", defaultValue: "More Group Actions…", bundle: .module) }
    static var more: String { String(localized: "sidebar.group.more", defaultValue: "Group options", bundle: .module) }
    static var collapse: String { String(localized: "sidebar.group.collapse", defaultValue: "Collapse group", bundle: .module) }
    static var expand: String { String(localized: "sidebar.group.expand", defaultValue: "Expand group", bundle: .module) }
    static var customColor: String { String(localized: "sidebar.groupColor.custom", defaultValue: "Custom color", bundle: .module) }
    static var emoji: String { String(localized: "sidebar.groupEditor.emoji", defaultValue: "Choose emoji or icon", bundle: .module) }

    /// A dot's spoken name: none, or the palette color's own name (group
    /// colors are a fixed palette, not the theme's).
    static func colorName(_ color: GroupColor) -> String {
        switch color {
        case .grey: String(localized: "sidebar.groupColor.none", defaultValue: "No color", bundle: .module)
        case .blue: String(localized: "sidebar.groupColor.blue", defaultValue: "Blue", bundle: .module)
        case .red: String(localized: "sidebar.groupColor.red", defaultValue: "Red", bundle: .module)
        case .yellow: String(localized: "sidebar.groupColor.yellow", defaultValue: "Yellow", bundle: .module)
        case .green: String(localized: "sidebar.groupColor.green", defaultValue: "Green", bundle: .module)
        case .pink: String(localized: "sidebar.groupColor.pink", defaultValue: "Pink", bundle: .module)
        case .purple: String(localized: "sidebar.groupColor.purple", defaultValue: "Purple", bundle: .module)
        case .cyan: String(localized: "sidebar.groupColor.cyan", defaultValue: "Cyan", bundle: .module)
        case .orange: String(localized: "sidebar.groupColor.orange", defaultValue: "Orange", bundle: .module)
        }
    }
}
