import AppKit
import CmuxNextDesign
import CmuxNextIcons

/// The "Done (N)", "Archived (N)" and "Show N more" rows at the end of a list (`SidebarLayout+DoneFold`): a chevron and the count in
/// the folder header's quiet style. A click opens or folds the rows it holds; it is no drop target and has no menu of
/// its own (its list's menu shows).
final class SidebarDoneFoldRowView: SidebarRowView {
    var isKeyboardFocused = false {
        didSet {
            performWithTheme {
                layer?.borderColor = Palette.focusRing.cgColor
                layer?.borderWidth = isKeyboardFocused ? Metrics.dividerThickness * 1.5 : 0
            }
            needsDisplay = true
        }
    }
    private let chevron = DecorativeImageView()
    private let name = SidebarRowView.label(font: SidebarStyle.headerFont)
    var onToggle: (() -> Bool)?

    required init(key: SidebarRowKey) {
        super.init(key: key)
        addSubview(chevron)
        addSubview(name)
    }

    func configure(_ row: SidebarRow) {
        switch row.key {
        case .showMore:
            name.setString(row.isCollapsed ? Strings.showMore(row.childCount) : Strings.showFewer)
        case let .doneFold(fold) where fold.kind == .archive:
            name.setString(Strings.archiveSection(row.childCount))
        case let .doneFold(fold) where fold.kind == .archived:
            name.setString(Strings.archivedFold(row.childCount))
        default:
            name.setString(Strings.doneFold(row.childCount))
        }
        name.setFont(SidebarStyle.headerFont)
        chevron.image = NSImage.icon(row.isCollapsed ? .disclosureCollapsed : .disclosureExpanded,
                                     size: .iconRowSize(forLabelPointSize: Metrics.smallIconSize - Metrics.space2))
        setAccessibilityElement(true)
        setAccessibilityRole(.disclosureTriangle)
        setAccessibilityLabel(name.stringValue)
        setAccessibilityExpanded(!row.isCollapsed)
        needsLayout = true
    }

    /// Whether the row draws its disclosure chevron (every fold row does; tests read it).
    var showsChevron: Bool { chevron.image != nil && !chevron.isHidden }

    override func accessibilityPerformPress() -> Bool {
        guard !isHiddenOrHasHiddenAncestor else { return false }
        return onToggle?() ?? false
    }

    override func prepareForReuse(key: SidebarRowKey) {
        super.prepareForReuse(key: key)
        onToggle = nil
    }

    override func layout() {
        super.layout()
        let b = layoutBounds
        let h = ceil(name.intrinsicContentSize.height)
        let icon = chevron.image?.size ?? .zero
        // The chevron starts where a row's title does, the count right after it.
        let start = SidebarStyle.titleLeading - SidebarStyle.labelCellPadding
        chevron.frame = NSRect(x: start, y: (b.height - icon.height) / 2, width: icon.width, height: icon.height)
        let x = chevron.frame.maxX + Metrics.space1
        name.frame = NSRect(x: x, y: (b.height - h) / 2, width: max(0, b.width - x - Metrics.space2), height: h)
        needsDisplay = true
    }

    override func updateLayer() {
        performWithTheme {
            layer?.borderColor = Palette.focusRing.cgColor
            layer?.borderWidth = isKeyboardFocused ? Metrics.dividerThickness * 1.5 : 0
            name.setColor(Palette.textSecondary)
            chevron.contentTintColor = Palette.textSecondary
        }
    }
}
