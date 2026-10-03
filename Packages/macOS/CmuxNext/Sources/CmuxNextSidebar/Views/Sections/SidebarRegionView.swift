import AppKit
import CmuxNextDesign
import QuartzCore

/// One sticky region (top or bottom) of the sidebar: the item sections of
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
    var onToggleSection: ((LayoutSectionID) -> Void)?
    var contextMenuProvider: ((SidebarContextTarget) -> NSMenu?)?
    /// The view of an app section (`SectionContent.app`), from the sidebar's provider.
    var appView: ((LayoutSection) -> NSView?)?
    private var appViews: [LayoutSectionID: NSView] = [:]

    private(set) var layoutResult = SidebarRegionLayout.empty
    private var content: Content?
    private var itemViews: [LayoutItemID: SidebarItemRowView] = [:]
    private var headerViews: [LayoutSectionID: SidebarSectionHeaderView] = [:]
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
        let result = SidebarRegionLayout.make(sections: content.sections, width: width, look: content.look,
                                              collapsed: content.collapsed, metrics: content.metrics,
                                              labelWidths: Self.labelWidths(content), appHeights: content.appHeights)
        guard content != self.content || result != layoutResult else { return }
        self.content = content
        layoutResult = result
        apply(content)
    }

    /// Icon + label width of every item of an inline section.
    private static func labelWidths(_ content: Content) -> [LayoutItemID: CGFloat] {
        var widths: [LayoutItemID: CGFloat] = [:]
        let font = SidebarStyle.titleFont
        for section in content.sections where section.arrangement.layout == .inline {
            for item in section.items where item.showsLabel {
                let info = content.infos[item.id] ?? .fallback(for: item.ref)
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
                view.frame = row.frame
            case let .app(id):
                guard let section = sections[id], let view = appViews[id] ?? appView?(section) else { continue }
                liveApps.insert(id)
                if view.superview !== self { addSubview(view) }
                appViews[id] = view
                view.frame = row.frame
            case let .item(id, sectionID), let .tile(id, sectionID), let .chip(id, sectionID):
                guard let section = sections[sectionID], let item = section.items.first(where: { $0.id == id }) else { continue }
                liveItems.insert(id)
                let view = itemViews[id] ?? makeItem(id)
                let style: SidebarItemRowView.Style = switch row.kind {
                case .tile: if case .grid = SectionFlow.mode(section, look: content.look) { .tile } else { .icon }
                case .chip: .chip
                default: section.look == .builtIn ? .builtIn : .list
                }
                view.configure(content.infos[id] ?? .fallback(for: item.ref), style: style)
                view.frame = row.frame
            }
        }
        for (id, view) in itemViews where !liveItems.contains(id) {
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
        view.onPress = { [weak self] in self?.onActivate?(id) }
        view.onContextMenu = { [weak self] event, view in
            guard let menu = self?.contextMenuProvider?(.layoutItem(id)) else { return }
            NSMenu.popUpContextMenu(menu, with: event, for: view)
        }
        addSubview(view)
        itemViews[id] = view
        return view
    }

    private func makeHeader(_ id: LayoutSectionID) -> SidebarSectionHeaderView {
        let view = SidebarSectionHeaderView()
        view.onPress = { [weak self] in self?.onToggleSection?(id) }
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
            for card in cardLayers { card.backgroundColor = Palette.hoverFill.cgColor }
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
