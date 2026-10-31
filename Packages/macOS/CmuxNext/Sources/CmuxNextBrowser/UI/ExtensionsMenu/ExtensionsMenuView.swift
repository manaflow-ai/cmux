import AppKit
import CmuxNextDesign
import CmuxNextIcons

/// The Extensions bubble's content: the best of Chrome's and Edge's Extensions menus in cmux's
/// popover look. The title "Extensions" with the current site under it and a close button; the
/// extensions grouped as Chrome groups them by what they can do on the site ("Can see and change
/// this site", "Allowed only when clicked", "No access needed"), each row with its access on a
/// second line (Edge); the list scrolls above ``ExtensionsMenuStyle/maxListHeight`` with a fade
/// at an edge that hides rows; then Manage Extensions and Get Extensions (the Chrome Web Store).
/// With no extensions it says so and offers the store.
///
/// Rows are kept by extension id and reused: an open shows the rows it already has and changes
/// only the ones whose extension changed.
final class ExtensionsMenuView: NSView {
    /// Callbacks of the bubble's controls.
    struct Actions {
        var run: (String) -> Void = { _ in }
        var sidePanel: (String) -> Void = { _ in }
        var pin: (String, Bool) -> Void = { _, _ in }
        var more: (String, NSView) -> Void = { _, _ in }
        var manage: () -> Void = {}
        var webStore: () -> Void = {}
        var close: () -> Void = {}
    }

    /// One listed extension and what the row shows of it.
    struct Entry {
        var info: BrowserExtensionInfo
        var icon: NSImage
        var access: ExtensionSiteAccess
        var canPin: Bool
        var hasSidePanel: Bool
        var tooltip: String?
    }

    var actions = Actions()
    private let style: ExtensionsMenuStyle
    private let titleLabel = ThemedLabel(labelWithString: "")
    private let siteLabel = ThemedLabel(labelWithString: "")
    let closeButton: ExtensionsMenuHoverButton
    private let scrollView = NSScrollView()
    private let fade: ScrollEdgeFadeView
    private let list = ExtensionsMenuListView()
    private var sectionLabels: [ExtensionSiteAccess.Group: ThemedLabel] = [:]
    private let empty: ExtensionsMenuEmptyView
    private let headerSeparator = ExtensionsMenuSeparator()
    private let footerSeparator = ExtensionsMenuSeparator()
    let manageButton: ExtensionsMenuHoverButton
    let webStoreButton: ExtensionsMenuHoverButton
    private(set) var rows: [ExtensionsMenuItemView] = []
    private var rowsByID: [String: ExtensionsMenuItemView] = [:]
    /// The list's sections in order, each with its rows.
    private var sections: [(ExtensionSiteAccess.Group, [ExtensionsMenuItemView])] = []
    /// Rows whose manifest was not read, after the sections and without a title.
    private var ungrouped: [ExtensionsMenuItemView] = []
    private var listHeight: CGFloat = 0

    init(style: ExtensionsMenuStyle = .standard) {
        self.style = style
        let glyphInset = (style.closeButton - style.closeGlyph) / 2
        closeButton = ExtensionsMenuHoverButton(
            image: NSImage.icon(.browserToolbarClose, size: style.closeGlyph), imageSize: style.closeGlyph, imageBox: style.closeGlyph,
            insets: NSEdgeInsets(top: glyphInset, left: glyphInset, bottom: glyphInset, right: glyphInset), style: style
        )
        let footerInsets = NSEdgeInsets(top: 0, left: style.rowInset, bottom: 0, right: style.rowInset)
        manageButton = ExtensionsMenuHoverButton(
            image: NSImage.icon(.browserExtensionsManage, size: style.footerIcon), imageSize: style.footerIcon,
            imageBox: style.extensionIconBox, title: Strings.extensionMenuTitle(.manage), insets: footerInsets,
            imageLabelSpacing: style.imageLabelSpacing, style: style
        )
        webStoreButton = ExtensionsMenuHoverButton(
            image: NSImage.icon(.browserExtensionsWebstore, size: style.footerIcon), imageSize: style.footerIcon,
            imageBox: style.extensionIconBox, title: Strings.extensionMenuGetExtensions, insets: footerInsets,
            imageLabelSpacing: style.imageLabelSpacing, style: style
        )
        fade = ScrollEdgeFadeView(scrollView: scrollView)
        empty = ExtensionsMenuEmptyView(style: style)
        super.init(frame: NSRect(x: 0, y: 0, width: style.width, height: 100))
        titleLabel.stringValue = Strings.extensions
        titleLabel.font = style.titleFont
        titleLabel.themeColor = { Palette.textPrimary }
        titleLabel.setAccessibilityRole(.staticText)
        siteLabel.font = style.subtitleFont
        siteLabel.themeColor = { Palette.textSecondary }
        siteLabel.lineBreakMode = .byTruncatingMiddle
        closeButton.setAccessibilityLabel(Strings.extensionMenuClose)
        closeButton.themedToolTip = Strings.extensionMenuClose
        closeButton.setAccessibilityIdentifier("\(ExtensionsMenu.menuIdentifier).close")
        closeButton.onPress = { [weak self] in self?.actions.close() }
        manageButton.setAccessibilityIdentifier(ExtensionsMenu.footerIdentifier(.manage))
        manageButton.onPress = { [weak self] in self?.actions.manage() }
        webStoreButton.setAccessibilityIdentifier(ExtensionsMenu.footerIdentifier(.webStore))
        webStoreButton.onPress = { [weak self] in self?.actions.webStore() }
        for group in ExtensionSiteAccess.Group.allCases {
            let label = ThemedLabel(labelWithString: Strings.extensionSection(group))
            label.font = style.sectionFont
            label.themeColor = { Palette.textSecondary }
            label.lineBreakMode = .byTruncatingTail
            label.setAccessibilityRole(.staticText)
            sectionLabels[group] = label
        }
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.verticalScrollElasticity = .none
        scrollView.documentView = list
        SystemScrollers.follow(scrollView)
        for view in [titleLabel, siteLabel, closeButton, headerSeparator, fade, empty, footerSeparator, manageButton,
                     webStoreButton] as [NSView] { addSubview(view) }
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    /// Shows `entries` grouped by their access on `site` (the current page's host, shown under the
    /// title; nil on a page that is no web site), each group in the entries' order. A row for an
    /// extension shown before is reused and updated in place; rows of extensions no longer listed
    /// go.
    func update(_ entries: [Entry], site: String?) {
        var byID: [String: ExtensionsMenuItemView] = [:]
        var grouped: [ExtensionSiteAccess.Group: [ExtensionsMenuItemView]] = [:]
        var ungrouped: [ExtensionsMenuItemView] = []
        for entry in entries {
            let info = entry.info
            let row: ExtensionsMenuItemView
            if let existing = rowsByID[info.id] {
                if existing.info != info || existing.access != entry.access || existing.canPin != entry.canPin
                    || existing.hasSidePanel != entry.hasSidePanel {
                    existing.apply(info, icon: entry.icon, access: entry.access, canPin: entry.canPin, hasSidePanel: entry.hasSidePanel)
                }
                row = existing
            } else {
                row = makeRow(entry)
            }
            row.primary.themedToolTip = entry.tooltip
            byID[info.id] = row
            if let group = entry.access.group { grouped[group, default: []].append(row) } else { ungrouped.append(row) }
        }
        for row in rows where byID[row.extensionID] == nil { row.removeFromSuperview() }
        sections = ExtensionSiteAccess.Group.allCases.compactMap { group in grouped[group].map { (group, $0) } }
        self.ungrouped = ungrouped
        rows = sections.flatMap(\.1) + ungrouped
        rowsByID = byID
        for row in rows where row.superview !== list { list.addSubview(row) }
        for (group, label) in sectionLabels {
            let shown = grouped[group] != nil
            if shown, label.superview !== list { list.addSubview(label) }
            if !shown { label.removeFromSuperview() }
        }
        siteLabel.stringValue = site ?? ""
        siteLabel.isHidden = site == nil
        empty.isHidden = !entries.isEmpty
        fade.isHidden = entries.isEmpty
        listHeight = entries.isEmpty ? 0
            : style.padding * 2 + CGFloat(sections.count) * style.sectionHeight + CGFloat(rows.count) * style.rowHeight
        setFrameSize(NSSize(width: style.width, height: headerHeight + 1 + visibleListHeight + 1 + footerHeight))
        needsLayout = true
    }

    private var headerHeight: CGFloat { style.headerHeight }
    private var footerHeight: CGFloat { style.padding * 2 + style.footerRowHeight * 2 }
    private var visibleListHeight: CGFloat { rows.isEmpty ? style.emptyHeight : min(listHeight, style.maxListHeight) }

    private func makeRow(_ entry: Entry) -> ExtensionsMenuItemView {
        let row = ExtensionsMenuItemView(info: entry.info, icon: entry.icon, access: entry.access, canPin: entry.canPin,
                                         hasSidePanel: entry.hasSidePanel, style: style)
        let id = entry.info.id
        row.onRun = { [weak self] in self?.actions.run(id) }
        row.onSidePanel = { [weak self] in self?.actions.sidePanel(id) }
        row.onPin = { [weak self] pinned in self?.actions.pin(id, pinned) }
        row.onMore = { [weak self, weak row] in
            guard let self, let row else { return }
            actions.more(id, row.moreButton)
        }
        return row
    }

    /// The row of extension `id`, when listed.
    func row(for id: String) -> ExtensionsMenuItemView? { rowsByID[id] }

    /// The titled sections shown, in order, each with its rows.
    var shownSections: [(ExtensionSiteAccess.Group, [ExtensionsMenuItemView])] { sections }

    /// The keyboard order: the rows' buttons, the footer, then the close button (Chrome's arrow
    /// keys walk the bubble's focus chain).
    var focusOrder: [NSView] { rows.flatMap(\.focusableButtons) + [manageButton, webStoreButton, closeButton] }

    override func layout() {
        super.layout()
        let inset = style.contentInset
        let width = bounds.width
        // Header: the title (and the site under it) centered on the close button's row.
        let closeX = width - style.padding - 4 - style.closeButton
        closeButton.frame = NSRect(x: closeX, y: (headerHeight - style.closeButton) / 2, width: style.closeButton,
                                   height: style.closeButton)
        let textWidth = max(0, closeX - inset - 8)
        let titleHeight = ceil(titleLabel.intrinsicContentSize.height)
        let siteHeight = siteLabel.isHidden ? 0 : ceil(siteLabel.intrinsicContentSize.height)
        let textTop = (headerHeight - titleHeight - siteHeight) / 2
        titleLabel.frame = NSRect(x: inset, y: textTop, width: textWidth, height: titleHeight)
        siteLabel.frame = NSRect(x: inset, y: textTop + titleHeight, width: textWidth, height: siteHeight)
        headerSeparator.frame = NSRect(x: 0, y: headerHeight, width: width, height: 1)

        // The list, or the empty state in its place.
        let listTop = headerSeparator.frame.maxY
        let visible = visibleListHeight
        fade.frame = NSRect(x: 0, y: listTop, width: width, height: visible)
        empty.frame = NSRect(x: 0, y: listTop, width: width, height: visible)
        list.frame = NSRect(x: 0, y: 0, width: width, height: listHeight)
        var y = style.padding
        for (group, rows) in sections {
            if let label = sectionLabels[group] {
                let height = ceil(label.intrinsicContentSize.height)
                // The title sits low in its band, close to the rows it names.
                label.frame = NSRect(x: inset, y: y + style.sectionHeight - height - 4, width: width - inset * 2, height: height)
            }
            y += style.sectionHeight
            for row in rows {
                row.frame = NSRect(x: style.padding, y: y, width: width - style.padding * 2, height: style.rowHeight)
                y += style.rowHeight
            }
        }
        for row in ungrouped {
            row.frame = NSRect(x: style.padding, y: y, width: width - style.padding * 2, height: style.rowHeight)
            y += style.rowHeight
        }

        // Footer.
        footerSeparator.frame = NSRect(x: 0, y: listTop + visible, width: width, height: 1)
        let footerTop = footerSeparator.frame.maxY + style.padding
        manageButton.frame = NSRect(x: style.padding, y: footerTop, width: width - style.padding * 2, height: style.footerRowHeight)
        webStoreButton.frame = NSRect(x: style.padding, y: manageButton.frame.maxY, width: width - style.padding * 2,
                                      height: style.footerRowHeight)
    }

    /// Scrolls the list so `view` (a row's button) shows: the keyboard moved onto it.
    func reveal(_ view: NSView) {
        guard view.isDescendant(of: list) else { return }
        list.scrollToVisible(view.convert(view.bounds, to: list).insetBy(dx: 0, dy: -style.padding))
    }
}

/// A flipped plain view: the list grows downward from its top.
private final class ExtensionsMenuListView: NSView {
    override var isFlipped: Bool { true }
}

/// The bubble with no extensions: Chrome's puzzle piece, "No extensions installed", and where to
/// find some (the footer's Get Extensions).
private final class ExtensionsMenuEmptyView: NSView {
    private let icon = ThemedImageView()
    private let title = ThemedLabel(labelWithString: Strings.noExtensions)
    private let detail = ThemedLabel(wrappingLabelWithString: Strings.extensionMenuEmptyDetail)
    private let style: ExtensionsMenuStyle

    init(style: ExtensionsMenuStyle) {
        self.style = style
        super.init(frame: .zero)
        icon.image = NSImage.icon(.browserToolbarExtensions, size: 28)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.themeTint = { Palette.textTertiary }
        title.font = style.titleFont
        title.themeColor = { Palette.textPrimary }
        title.alignment = .center
        detail.font = style.detailFont
        detail.themeColor = { Palette.textSecondary }
        detail.alignment = .center
        for view in [icon, title, detail] { addSubview(view) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let width = bounds.width - style.contentInset * 2
        let titleHeight = ceil(title.intrinsicContentSize.height)
        detail.preferredMaxLayoutWidth = width
        let detailHeight = ceil(detail.intrinsicContentSize.height)
        let iconSide: CGFloat = 28
        let total = iconSide + 10 + titleHeight + 2 + detailHeight
        var y = (bounds.height - total) / 2
        icon.frame = NSRect(x: (bounds.width - iconSide) / 2, y: y, width: iconSide, height: iconSide)
        y += iconSide + 10
        title.frame = NSRect(x: style.contentInset, y: y, width: width, height: titleHeight)
        y += titleHeight + 2
        detail.frame = NSRect(x: style.contentInset, y: y, width: width, height: detailHeight)
    }
}

/// A one-point line in the theme's separator color (Chrome's `views::Separator`).
private final class ExtensionsMenuSeparator: NSView {
    override func draw(_ dirtyRect: NSRect) {
        performWithTheme {
            Palette.separator.setFill()
            bounds.fill()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
