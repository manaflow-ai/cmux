import AppKit
import CmuxNextDesign
import QuartzCore

/// One pinned region (top or bottom) of the sidebar: the item sections of
/// that region, drawn in the current look variant. It sizes to its content;
/// `SidebarView` puts it in a scroll view capped by the region's share.
final class SidebarRegionView: NSView {
    struct Content: Equatable {
        var sections: [LayoutSection]
        var infos: [LayoutItemID: SidebarItemInfo]
        var collapsed: Set<LayoutSectionID>
        var look: SectionsLookVariant
        var metrics: SidebarRegionMetrics
        /// `appearance.borders`: lines, or the tonal step under none.
        var drawsLines: Bool
        /// Content height of each shown app section (none: draws nothing).
        var appHeights: [LayoutSectionID: CGFloat] = [:]
    }

    let region: SidebarRegion
    var onActivate: ((LayoutItemID) -> Void)?
    /// An item's trailing control was pressed.
    var onActivateWithModifiers: ((LayoutItemID, NSEvent.ModifierFlags) -> Void)?
    var onToggleSection: ((LayoutSectionID) -> Void)?
    /// A drag dropped `subject`: the shown sections in their new order (R77).
    var onReorder: ((SidebarRegionDragSubject, [LayoutSection]) -> Void)?
    /// Whether a window point is over the workspace list (a workspace tile
    /// dropped there unpins); nil point ends the drag. The sidebar outlines the list.
    var dropToListProbe: ((NSPoint?) -> Bool)?
    /// A workspace item was dropped on the list.
    var onDropToList: ((LayoutItemID) -> Void)?
    var contextMenuProvider: ((SidebarContextTarget) -> NSMenu?)?
    /// The region's height changed outside its host's layout (a drag's
    /// preview, a landed drop): the host lays its bands out again.
    var onHeightChange: (() -> Void)?
    /// The view of an app section (`SectionContent.app`), from the sidebar's provider.
    var appView: ((LayoutSection) -> NSView?)?
    private(set) var appViews: [LayoutSectionID: NSView] = [:]

    private(set) var layoutResult = SidebarRegionLayout.empty
    private(set) var content: Content?
    private(set) var itemViews: [LayoutItemID: SidebarItemRowView] = [:]
    private(set) var headerViews: [LayoutSectionID: SidebarSectionHeaderView] = [:]
    /// The drag in progress (R77) and the order the region shows while it
    /// runs and until its card has landed.
    var reorder: SidebarRegionDrag?
    /// Where a drag's lifted card lives: a view above the band's scroll
    /// view (the sidebar), so the card and its shadow are never clipped to
    /// the band. Nil: the region itself (tests, a region on its own).
    weak var liftHost: NSView?
    /// Items and sections can be dragged to reorder. The footer band's
    /// cannot (SIDEBAR-FOOTER-AND-SPACE-MENU amendment 3: no drag and drop
    /// in the footer row for now).
    var allowsDrag = true
    var reorderSections: [LayoutSection]?
    private var width: CGFloat = 0
    private var animatesFrames = false
    private var cardLayers: [CALayer] = []
    /// Section lines (lines looks), or under `appearance.borders = none`
    /// the tonal step: every other section a shade lighter.
    private var lineLayers: [CALayer] = []
    private var drawsLines = true

    init(region: SidebarRegion) {
        self.region = region
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Height the content needs at `width`.
    func update(_ content: Content, width: CGFloat) {
        let shown = displayed(content)
        let result = Self.layout(shown, width: width)
        guard content != self.content || result != layoutResult else { return }
        self.content = content
        self.width = width
        layoutResult = result
        apply(shown)
    }

    /// Lays out the shown order again; animated, every row springs to its frame.
    func relayout(animated: Bool) {
        guard let content else { return }
        let shown = displayed(content)
        let height = layoutResult.height
        layoutResult = Self.layout(shown, width: width)
        if layoutResult.height != height { onHeightChange?() }
        guard animated else { return apply(shown) }
        Motion.animate(.move, in: self, {
            self.animatesFrames = true
            self.apply(shown)
            self.animatesFrames = false
        }, completion: { [weak self] in
            // The rows ended their move under a possibly still pointer (cx-3wu5).
            PointerHover.refresh(in: self?.window)
        })
    }

    private func displayed(_ content: Content) -> Content {
        var shown = content
        if let reorderSections { shown.sections = reorderSections }
        return shown
    }

    private static func layout(_ content: Content, width: CGFloat) -> SidebarRegionLayout {
        SidebarRegionLayout.make(sections: content.sections, width: width, look: content.look,
                                 collapsed: content.collapsed, metrics: content.metrics,
                                 labelWidths: labelWidths(content), appHeights: content.appHeights,
                                 iconWidths: iconWidths(content))
    }

    /// Icon-only items wider than a square: the profile avatar and its
    /// chevron (SIDEBAR-FOOTER-AND-SPACE-MENU amendment 2).
    private static func iconWidths(_ content: Content) -> [LayoutItemID: CGFloat] {
        var widths: [LayoutItemID: CGFloat] = [:]
        for section in content.sections {
            for item in section.items where content.infos[item.id]?.avatar != nil {
                widths[item.id] = SidebarStyle.avatarControlWidth
            }
        }
        return widths
    }

    private func place(_ view: NSView, _ frame: CGRect) {
        if animatesFrames { view.animator().frame = frame } else { view.frame = frame }
    }

    /// Icon + label width of every item of an inline section.
    private static func labelWidths(_ content: Content) -> [LayoutItemID: CGFloat] {
        var widths: [LayoutItemID: CGFloat] = [:]
        let font = SidebarStyle.titleFont
        // Inline lines and span grids (R53) draw labeled items with icon and label.
        for section in content.sections where section.arrangement.layout == .inline
            || (section.arrangement.layout == .grid && section.items.contains { $0.span != nil }) {
            for item in section.items where item.showsLabel {
                let info = content.infos[item.id] ?? .fallback(for: item)
                widths[item.id] = SidebarItemRowView.chipWidth(title: info.title, font: font, badge: info.badge)
            }
        }
        return widths
    }

    private func apply(_ content: Content) {
        let sections = Dictionary(content.sections.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var liveItems = Set<LayoutItemID>(), liveHeaders = Set<LayoutSectionID>(), liveApps = Set<LayoutSectionID>()
        for row in layoutResult.rows {
            switch row.kind {
            case let .header(id):
                guard let section = sections[id] else { continue }
                liveHeaders.insert(id)
                let view = headerViews[id] ?? makeHeader(id)
                view.configure(title: section.title ?? "", collapsed: content.collapsed.contains(id))
                place(view, row.frame)
            case let .app(id):
                guard let section = sections[id], let view = appViews[id] ?? appView?(section) else { continue }
                liveApps.insert(id)
                if view.superview !== self { addSubview(view) }
                appViews[id] = view
                place(view, row.frame)
            case let .item(id, sectionID), let .tile(id, sectionID), let .chip(id, sectionID):
                guard let section = sections[sectionID], let item = section.items.first(where: { $0.id == id }) else { continue }
                liveItems.insert(id)
                let view = itemViews[id] ?? makeItem(id)
                let style: SidebarItemRowView.Style = switch row.kind {
                // An icon-only built-in item (the account, an icon-only Settings)
                // has no fill until hover in every arrangement (Lawrence
                // 2026-10-05: "account icon should not have bg unless i hover").
                case .tile:
                    switch SectionFlow.mode(section, look: content.look) {
                    case .tiles?: .favorite
                    case .grid?: item.ref.builtIn != nil ? .icon : .tile
                    default: .icon
                    }
                case .chip: .chip
                default: section.look == .builtIn ? .builtIn : .list
                }
                view.configure(content.infos[id] ?? .fallback(for: item), style: style)
                place(view, row.frame)
            }
        }
        // A dragged item's view owns the press (AppKit sends it the drags
        // and the release): it stays, hidden, while a preview leaves it out.
        let pressed = Set((reorder?.hidden ?? []).map(ObjectIdentifier.init))
        for (id, view) in itemViews where !liveItems.contains(id) && !pressed.contains(ObjectIdentifier(view)) {
            view.removeFromSuperview()
            itemViews[id] = nil
        }
        for (id, view) in appViews where !liveApps.contains(id) {
            view.removeFromSuperview()
            appViews[id] = nil
        }
        for (id, view) in headerViews where !liveHeaders.contains(id) {
            view.removeFromSuperview()
            headerViews[id] = nil
        }
        // Rows reflowed under a possibly still pointer (cx-3wu5).
        PointerHover.refresh(in: window)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        while cardLayers.count > layoutResult.cards.count { cardLayers.removeLast().removeFromSuperlayer() }
        while cardLayers.count < layoutResult.cards.count {
            let card = CALayer()
            card.cornerCurve = .continuous
            layer?.insertSublayer(card, at: 0)
            cardLayers.append(card)
        }
        for (card, frame) in zip(cardLayers, layoutResult.cards) {
            card.frame = frame
            card.cornerRadius = SidebarStyle.rowCornerRadius + Metrics.space1
        }
        drawsLines = Borders.drawsLines
        let lineFrames = drawsLines ? layoutResult.separators
            : content.look.separatesSections ? layoutResult.sectionFrames.enumerated().filter { $0.offset % 2 == 1 }.map(\.element) : []
        while lineLayers.count > lineFrames.count { lineLayers.removeLast().removeFromSuperlayer() }
        while lineLayers.count < lineFrames.count {
            let line = CALayer()
            layer?.insertSublayer(line, at: 0)
            lineLayers.append(line)
        }
        for (line, frame) in zip(lineLayers, lineFrames) { line.frame = frame }
        CATransaction.commit()
        needsDisplay = true
    }

    private func makeItem(_ id: LayoutItemID) -> SidebarItemRowView {
        let view = SidebarItemRowView()
        view.onPressWithModifiers = { [weak self] flags in
            if let onActivateWithModifiers = self?.onActivateWithModifiers {
                onActivateWithModifiers(id, flags)
            } else {
                self?.onActivate?(id)
            }
        }
        addSubview(view)
        itemViews[id] = view
        // A client-only item (What's New) only opens: no drag, no menu.
        guard !id.isTransient else { return view }
        view.onDragged = { [weak self] start, event in self?.dragMoved(.item(id), from: start, event) ?? false }
        view.onDragEnded = { [weak self] in self?.finishDrag() }
        view.onContextMenu = { [weak self] event, view in
            guard let menu = self?.contextMenuProvider?(.layoutItem(id)) else { return }
            NSMenu.popUpContextMenu(menu, with: event, for: view)
        }
        return view
    }

    private func makeHeader(_ id: LayoutSectionID) -> SidebarSectionHeaderView {
        let view = SidebarSectionHeaderView()
        view.onPress = { [weak self] in self?.onToggleSection?(id) }
        view.onDragged = { [weak self] start, event in self?.dragMoved(.section(id), from: start, event) ?? false }
        view.onDragEnded = { [weak self] in self?.finishDrag() }
        view.onContextMenu = { [weak self] event, view in
            guard let menu = self?.contextMenuProvider?(.layoutSection(id)) else { return }
            NSMenu.popUpContextMenu(menu, with: event, for: view)
        }
        addSubview(view)
        headerViews[id] = view
        return view
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        performWithTheme {
            // A tiles card takes the next tonal step so it reads as its own
            // shelf above the session list, not one more card.
            for (index, card) in cardLayers.enumerated() {
                let fill = layoutResult.tiledCards.contains(index) ? Palette.selectionFill : Palette.hoverFill
                card.backgroundColor = fill.cgColor
            }
            let lineColor = drawsLines ? Palette.separator : Palette.hoverFill.withAlphaComponent(Palette.hoverFill.alphaComponent * 0.6)
            for line in lineLayers { line.backgroundColor = lineColor.cgColor }
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        contextMenuProvider?(.background)
    }

    /// The item view for `id` (tests, hover cards).
    func itemView(_ id: LayoutItemID) -> SidebarItemRowView? { itemViews[id] }
}
