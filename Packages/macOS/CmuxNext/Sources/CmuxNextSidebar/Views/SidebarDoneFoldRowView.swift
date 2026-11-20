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
        let columns = SidebarStyle.columns(rowWidth: b.width)
        let h = ceil(name.intrinsicContentSize.height)
        // Done and Show N more use the shared trailing fold column; their label uses the common text line.
        chevron.frame = columns.trailingFrame(centerY: b.midY, side: SidebarStyle.controlSize)
        let x = columns.text(hasLeadingMark: false) - SidebarStyle.labelCellPadding
        name.frame = NSRect(x: x, y: columns.textOriginY(centerY: b.midY, baseline: name.firstBaselineOffsetFromTop,
                                                           capHeight: name.font?.capHeight ?? SidebarStyle.headerFont.capHeight),
                             width: max(0, columns.textEnd(trailingMarks: 1) - x), height: h)
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
