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
        /// The label font's size (`SidebarStyle.titleFont`): label widths are measured with it.
        var fontSize: CGFloat = 0
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
    /// The older path's drag out (the list's `removesOnDragOut` and `onDragOutRemove`): an item released beside the sidebar comes off it.
    var removesOnDragOut: ((String) -> Bool)?
    var onDragOutRemove: ((String) -> Void)?
    /// The list this region draws one section in (the sidebar document's
    /// one renderer, `SidebarBlockRowView`): its item drags are the list's.
    weak var docList: SidebarListView?
    /// The item whose press the list's drag holds (it stays in the window, hidden, until the release).
    var docPressedItem: LayoutItemID?
    /// A press the list's drag ended early (a cancel): it drags nothing more until its release.
    var docSpentPress: LayoutItemID?
    var contextMenuProvider: ((SidebarContextTarget) -> NSMenu?)?
    /// The sidebar's edit mode (`SidebarView.isEditingItems`): every item but a client-only one
    /// wiggles and shows its ✕, which asks `onRemoveItem` to take it out.
    var isEditing = false {
        didSet { if isEditing != oldValue { for (id, view) in itemViews { edit(view, id) } } }
    }
    var onRemoveItem: ((LayoutItemID) -> Void)?
    /// The region's height changed outside its host's layout (a drag's
    /// preview, a landed drop): the host lays its bands out again.
    var onHeightChange: (() -> Void)?
    /// The view of an app section (`SectionContent.app`), from the sidebar's provider.
    var appView: ((LayoutSection) -> NSView?)?
    private(set) var appViews: [LayoutSectionID: NSView] = [:]
    /// The band's alpha at rest while minimal mode hides it: faded, unless it
    /// holds All chats, whose rows stay and whose header alone fades with the
    /// hover (cx-xub5; only the footer row then hides).
    func restAlpha(hiddenByMode: Bool) -> CGFloat {
        hiddenByMode && !appViews.values.contains(where: { $0 is SidebarHoverRevealing }) ? 0 : 1
    }

    /// The sidebar's hover reveal, passed to app views whose chrome fades with
    /// it (`SidebarHoverRevealing`: the All chats header).
    var chromeRevealed = false {
        didSet {
            guard oldValue != chromeRevealed else { return }
            for view in appViews.values { (view as? SidebarHoverRevealing)?.setHoverRevealed(chromeRevealed) }
        }
    }

    private(set) var layoutResult = SidebarRegionLayout.empty
    private(set) var content: Content?
    /// The selected top item (`SidebarModel.selectedItem`), drawn active. Kept out of `Content`:
    /// a selection change repaints the old and new item only, never lays the region out
    /// (plans/cmux-next/perf-speed-of-light.md I6).
    var activeItem: LayoutItemID? {
        didSet {
            guard oldValue != activeItem else { return }
            for id in [oldValue, activeItem].compactMap({ $0 }) {
                guard let view = itemViews[id] else { continue }
                view.configure(activeInfo(view.info, id), style: view.style)
            }
        }
    }
    /// The sidebar's multi-selection (`SidebarModel.selection`): a pinned workspace's tile in it draws
    /// the secondary fill a selected list row draws. Only the tiles that joined or left repaint.
    var selectedWorkspaces: Set<WorkspaceID> = [] {
        didSet {
            let changed = oldValue.symmetricDifference(selectedWorkspaces)
            guard !changed.isEmpty else { return }
            for (id, view) in itemViews where view.info.workspace.map(changed.contains) == true {
                view.configure(activeInfo(view.info, id), style: view.style)
            }
        }
    }
    private(set) var itemViews: [LayoutItemID: SidebarItemRowView] = [:]
    private(set) var headerViews: [LayoutSectionID: SidebarSectionHeaderView] = [:]
    /// The drag in progress (R77) and the order the region shows while it
    /// runs and until its card has landed.
    var reorder: SidebarRegionDrag? { didSet { followPointerEnd(from: oldValue) } }
    /// Where a drag's lifted card lives: a view above the band's scroll
    /// view (the sidebar), so the card and its shadow are never clipped to
    /// the band. Nil: the region itself (tests, a region on its own).
    weak var liftHost: NSView?
    /// Items and sections can be dragged to reorder. The footer band's
    /// cannot (SIDEBAR-FOOTER-AND-SPACE-MENU amendment 3: no drag and drop
    /// in the footer row for now).
    var allowsDrag = true
    /// What a right-click on empty space targets: the band's own target for the footer.
    var emptySpaceTarget: SidebarContextTarget = .background
    var reorderSections: [LayoutSection]?
    private var width: CGFloat = 0
    private var animatesFrames = false
    /// Frames go to their place on the drag's additive spring (`springShow`); a new view is placed at once.
    private var springsFrames = false
    /// Card backgrounds by section: a card keeps its layer (and its spring) when sections are added, removed or reordered.
    private var cardLayers: [LayoutSectionID: CALayer] = [:]
    /// Section lines (lines looks), or under `appearance.borders = none`
    /// the tonal step: every other section a shade lighter. By key (the section below a line, or `tone:<section>`).
    private var lineLayers: [String: CALayer] = [:]
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

    nonisolated override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Height the content needs at `width`.
    func update(_ content: Content, width: CGFloat) {
        // `layoutResult` is always the layout of the shown content at `width`
        // (`relayout` keeps it so), so the same inputs need no new layout.
        if content == self.content && width == self.width { return }
        SidebarPerfCounters.add(.bandUpdates)
        let shown = displayed(content)
        let result = Self.layout(shown, width: width)
        guard content != self.content || result != layoutResult else {
            self.width = width
            return
        }
        self.content = content
        self.width = width
        layoutResult = result
        apply(shown)
    }

    /// Lays the shown content out again at `width` when that differs from the width it was
    /// laid out at: a list block's row is resized with the list (a sidebar resize), and its
    /// rows must take the new width, not keep the one they were first laid out at.
    func fit(width: CGFloat) {
        guard width != self.width, let content else { return }
        update(content, width: width)
    }

    /// Shows `content` (a list block, `SidebarBlockRowView`): animated, the
    /// items spring to their new frames, as the list's rows do for a gap.
    func show(_ content: Content, width: CGFloat, animated: Bool) {
        guard animated, self.content != nil, content != self.content || width != self.width else { return update(content, width: width) }
        self.content = content
        self.width = width
        relayout(animated: true)
    }

    /// Shows `content` with every item, header, card and line on the drag's
    /// one additive spring (`SidebarDragSpring`): a drag's gap opens and
    /// closes, a drop adopts its slot, with no re-layout jump. The height
    /// change does not call `onHeightChange`: the list moves the rows below
    /// with the same spring.
    func springShow(_ content: Content, width: CGFloat) {
        guard self.content != nil else { return update(content, width: width) }
        guard content != self.content || width != self.width else { return }
        self.content = content
        self.width = width
        let shown = displayed(content)
        layoutResult = Self.layout(shown, width: width)
        springsFrames = true
        apply(shown)
        springsFrames = false
    }

    /// The layout of `content` at `width` (a list block's height and hit test).
    static func layout(of content: Content, width: CGFloat) -> SidebarRegionLayout { layout(content, width: width) }

    /// Lays out the shown order again; animated, every row springs to its frame.
    func relayout(animated: Bool) {
        guard let content else { return }
        let shown = displayed(content)
        let height = layoutResult.height
        layoutResult = Self.layout(shown, width: width)
        if layoutResult.height != height { onHeightChange?() }
        guard animated else { return apply(shown) }
        Motion.sidebar.animate(.move, in: self, {
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
                                 labelWidths: labelWidths(content, width: width), appHeights: content.appHeights)
    }

    private func place(_ view: NSView, _ frame: CGRect, new: Bool = false) {
        if springsFrames, !new { return SidebarDragSpring.move(view, to: frame) }
        if animatesFrames, !new { view.animator().frame = frame } else if springsFrames { Motion.withoutAnimation { view.frame = frame } } else { view.frame = frame }
    }

    private func apply(_ content: Content) {
        let sections = Dictionary(content.sections.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var liveItems = Set<LayoutItemID>(), liveHeaders = Set<LayoutSectionID>(), liveApps = Set<LayoutSectionID>()
        for row in layoutResult.rows {
            switch row.kind {
            case let .header(id):
                guard let section = sections[id] else { continue }
                liveHeaders.insert(id)
                let new = headerViews[id] == nil
                let view = headerViews[id] ?? makeHeader(id)
                view.configure(title: section.title ?? "", collapsed: content.collapsed.contains(id))
                view.trailingTrim = SidebarRegionLayout.itemTrailingTrim(section, look: content.look, metrics: content.metrics)
                view.setAccessibilityIdentifier("cmux.sidebar.region.\(id.rawValue)")
                place(view, row.frame, new: new)
            case let .app(id):
                guard let section = sections[id], let view = appViews[id] ?? appView?(section) else { continue }
                liveApps.insert(id)
                let new = view.superview !== self
                if view.superview !== self {
                    addSubview(view)
                    (view as? SidebarHoverRevealing)?.setHoverRevealed(chromeRevealed)
                }
                appViews[id] = view
                place(view, row.frame, new: new)
            case let .item(id, sectionID), let .tile(id, sectionID), let .chip(id, sectionID):
                guard let section = sections[sectionID], let item = section.items.first(where: { $0.id == id }) else { continue }
                liveItems.insert(id)
                let new = itemViews[id] == nil
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
                var info = activeInfo(content.infos[id] ?? .fallback(for: item), id)
                info.leadingPin = !style.isIconOnly && style != .chip && sectionID == SidebarLayoutDocument.pinnedSectionID
                    && item.ref.kind == LayoutItemRef.workspaceKind
                view.configure(info, style: style)
                view.setAccessibilityIdentifier("cmux.sidebar.item.\(id.rawValue)")
                view.activatesOnPress = item.ref.activatesOnPress
                view.isMovable = item.isMovable // Home's press never drags (`LayoutItem.isMovable`)
                place(view, row.frame, new: new)
                if id == SidebarListBlocks.gapID { view.alphaValue = 0 } // a drag's gap: the slot the others make way for
                edit(view, id)
            }
        }
        // A dragged item's view owns the press (AppKit sends it the drags
        // and the release): it stays, hidden, while a preview leaves it out.
        var pressed = Set((reorder?.hidden ?? []).map(ObjectIdentifier.init))
        // A list block's tile the list's drag lifted: it holds the press, so it stays (hidden) until the release.
        if let id = docPressedItem, let view = itemViews[id], !liveItems.contains(id) {
            pressed.insert(ObjectIdentifier(view))
            view.alphaValue = 0
        }
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
        // Cards and lines are matched by section, not by position: a section added above another
        // keeps that one's card on its spring instead of moving a neighbour's card into its place.
        let cards = Dictionary(zip(layoutResult.cardSections, layoutResult.cards), uniquingKeysWith: { a, _ in a })
        for (id, card) in cardLayers where cards[id] == nil {
            card.removeFromSuperlayer()
            cardLayers[id] = nil
        }
        for (id, frame) in cards {
            if let card = cardLayers[id] {
                if springsFrames { SidebarDragSpring.move(card, to: frame) } else { card.frame = frame }
                continue
            }
            let card = CALayer()
            card.cornerCurve = .continuous
            card.cornerRadius = SidebarStyle.rowCornerRadius + Metrics.space1
            layer?.insertSublayer(card, at: 0)
            card.frame = frame
            cardLayers[id] = card
        }
        drawsLines = Borders.drawsLines
        let lineFrames: [(String, CGRect)] = drawsLines ? Array(zip(layoutResult.separatorKeys, layoutResult.separators))
            : content.look.separatesSections
            ? zip(layoutResult.sectionIDs, layoutResult.sectionFrames).enumerated().filter { $0.offset % 2 == 1 }.map { ("tone:" + $0.element.0.rawValue, $0.element.1) }
            : []
        let lines = Dictionary(lineFrames, uniquingKeysWith: { a, _ in a })
        for (key, line) in lineLayers where lines[key] == nil {
            line.removeFromSuperlayer()
            lineLayers[key] = nil
        }
        for (key, frame) in lines {
            if let line = lineLayers[key] {
                if springsFrames { SidebarDragSpring.move(line, to: frame) } else { line.frame = frame }
                continue
            }
            let line = CALayer()
            layer?.insertSublayer(line, at: 0)
            line.frame = frame
            lineLayers[key] = line
        }
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
        view.onPressBegan = { [weak self] in self?.endStaleDrag() }
        addSubview(view)
        itemViews[id] = view
        // A client-only item (What's New) only opens: no drag, no menu.
        guard !id.isTransient else { return view }
        view.onDragged = { [weak self] start, event in self?.dragMoved(.item(id), from: start, event) ?? false }
        view.onDragEnded = { [weak self] point in self?.finishDrag(at: point) }
        view.onRemove = { [weak self] in self?.onRemoveItem?(id) }
        view.onContextMenu = { [weak self] event, view in
            guard let menu = self?.contextMenuProvider?(.layoutItem(id)) else { return }
            NSMenu.popUpContextMenu(menu, with: event, for: view)
        }
        // A workspace tile's hover more button opens the same menu under itself (SidebarItemRowView+HoverActions).
        // A pinned item has no hover x (Lawrence msg 19392): Close Workspace is in this menu.
        view.onMore = { [weak self, weak view] in
            guard let view, let button = view.hoverMore, let menu = self?.contextMenuProvider?(.layoutItem(id)) else { return }
            view.showsMenu = true
            defer { view.showsMenu = false }
            _ = menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.isFlipped ? button.bounds.maxY : 0), in: button)
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

    nonisolated override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        performWithTheme {
            // A tiles card takes the next tonal step so it reads as its own
            // shelf above the session list, not one more card.
            let tiled = Set(layoutResult.tiledCards.compactMap { layoutResult.cardSections.indices.contains($0) ? layoutResult.cardSections[$0] : nil })
            for (id, card) in cardLayers {
                let fill = tiled.contains(id) ? Palette.selectionFill : Palette.hoverFill
                card.backgroundColor = fill.cgColor
            }
            let lineColor = drawsLines ? Palette.separator : Palette.hoverFill.withAlphaComponent(Palette.hoverFill.alphaComponent * 0.6)
            for line in lineLayers.values { line.backgroundColor = lineColor.cgColor }
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        contextMenuProvider?(emptySpaceTarget)
    }

    /// `info` drawn active when `id` is the selected item, and as part of the multi-selection when its workspace is.
    private func activeInfo(_ info: SidebarItemInfo, _ id: LayoutItemID) -> SidebarItemInfo {
        var info = info
        info.isActive = id == activeItem
        info.isSecondarySelected = !info.isActive && info.workspace.map(selectedWorkspaces.contains) == true
        return info
    }

    /// The item view for `id` (tests, hover cards).
    func itemView(_ id: LayoutItemID) -> SidebarItemRowView? { itemViews[id] }

    /// Up and Down from a focused item walk the whole sidebar (`SidebarArrowWalk`).
    override func keyDown(with event: NSEvent) {
        if let item = window?.firstResponder as? SidebarItemRowView, SidebarArrowWalk.step(from: item, event) { return }
        super.keyDown(with: event)
    }
}
