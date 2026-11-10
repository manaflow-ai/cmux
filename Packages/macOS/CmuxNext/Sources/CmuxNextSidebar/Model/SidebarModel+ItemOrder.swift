public import CmuxNextDesign

extension SidebarModel {
    /// This sidebar's destinations in shown order (``SidebarItemOrder``): the
    /// top region's visible items (hidden, missing and suppressed apps' items
    /// skipped), then the list's selectable rows in drawn order (the sidebar's
    /// own row layout, so collapsed sections and rows the filter hides are not
    /// stops). A collapsed group is one stop; an empty one is none. The rows are
    /// laid out with the list's own row options (`rowOptions`): a workspace folded
    /// into a "Done (N)" row or hidden behind "Show N more" is no stop until its
    /// fold opens (Leo 2026-11-07: Cmd-1…7 next to a group "messes things up a ton").
    ///
    /// Made once per change of what it reads (`SidebarItemOrderInputs`), so
    /// a Cmd-1…9 or Cmd-Ctrl-[ / ] press costs a key compare, not a layout
    /// of every row. The selection is not an input: the order never depends on it.
    public var itemOrder: SidebarItemOrder {
        let inputs = SidebarItemOrderInputs(self)
        if let cached = itemOrderCache, cached.inputs == inputs { return cached.order }
        let order = makeItemOrder()
        itemOrderCache = (inputs, order)
        return order
    }

    /// The item `offset` steps from `selected` (Cmd-Ctrl-] is +1). A workspace with no stop of its own (folded into
    /// "Done (N)", behind "Show N more", in the closed Archive) steps to the stops drawn around it when selected: that
    /// one lays the list out with it active, as the list does on every selection. Any other selection steps in the
    /// order's own sequence, a key compare, so repeated presses walk every stop once: a row an opened fold lists at
    /// its end steps from there even though, selected, it draws in its place (a walk from where it draws would come
    /// back to it forever).
    public func step(from selected: SidebarItem?, by offset: Int, _ settings: SidebarNavigationSettings) -> SidebarItem? {
        let order = itemOrder
        guard case .workspace(let id)? = selected, order.stop(for: selected) == nil,
              let ws = workspace(id), !ws.rowState.isPending else {
            return order.step(from: selected, by: offset, settings)
        }
        return order.step(from: selected, by: offset, settings, place: drawnPlace(of: id, in: order))
    }

    /// Where `id` draws among `order.rows` when it is the active workspace: the index after the last stop drawn
    /// before it. Nil when the list draws it nowhere even then (a member of a collapsed parent's subgroup).
    private func drawnPlace(of id: WorkspaceID, in order: SidebarItemOrder) -> Int? {
        var source = orderSource()
        source.options.activeWorkspaceID = id
        let drawn = orderRows(source).rows
        guard let at = drawn.firstIndex(of: .workspace(id)) else { return nil }
        var index: [SidebarItem: Int] = [:]
        for (i, item) in order.rows.enumerated() where index[item] == nil { index[item] = i }
        return drawn[..<at].reversed().lazy.compactMap { index[$0] }.first.map { $0 + 1 } ?? 0
    }

    private func makeItemOrder() -> SidebarItemOrder {
        let source = orderSource()
        let (rows, stops) = orderRows(source)
        let topItems = source.top.filter { item in !source.listed.contains(source.inBlock.first { $0.value.contains(item) }?.key ?? "") }
        return SidebarItemOrder(topItems: topItems.map { .topItem($0.id) }, rows: rows, stops: stops)
    }

    /// What the order lays out: the top items, the blocks they draw in, and the list's row options.
    private struct OrderSource {
        var top: [LayoutItem]
        var inBlock: [String: [LayoutItem]]
        var listed: Set<String>
        var options: SidebarLayoutOptions
    }

    private func orderSource() -> OrderSource {
        // An anchored client item (Channels after Home) is a stop at its place, placed among the shown items as
        // the band draws it (a hidden Home is no anchor); other client items are not stops.
        let hidden = Set(itemInfo.filter(\.value.isHidden).keys)
        let shown = layout.sections(in: .top, room: activeProfileID?.rawValue).presenting(hidingItems: hidden, apps: suppressedApps)
        let placed = placingTransientItems(in: shown, anchoredOnly: true)
        let top = placed.flatMap(\.items).filter { item in
            let info = itemInfo[item.id]
            return info?.isHidden != true && info?.isMissing != true && !suppressedApps.contains(item.owningAppID ?? "")
        }
        // As the list draws its rows, without the selection: the active workspace keeps its place in a fold when the
        // list draws it, but it is no stop of its own, so no number moves when it is selected.
        var options = rowOptions() // hidesWorkspaces stays off: Cmd-1…9 reach workspaces with the Projects list hidden
        // Every project is a stop, past the first five too: the order ignores the projects list's Show more.
        options.openShowMore.insert(.projects)
        // The session tree moves a started workspace under its parent: the numbers follow the drawn order.
        options.sessionTree = SidebarSessionTree.shared.drawn?.shape
        // The sidebar document draws its sections in the list: a block's items are stops where the block draws.
        let listed = Set(sections.compactMap { section -> String? in if case let .custom(custom) = section.kind { custom.id } else { nil } })
        // A client item belongs to the section it is placed in (a remote chat under Home), not to no section:
        // else it would be a band stop ahead of the block's Home and take Cmd-1.
        let inBlock = Dictionary(grouping: top, by: { item in placed.first { $0.items.contains(item) }?.id.rawValue ?? "" })
        for id in listed { options.blockHeights[id] = 1 }
        options.collapsedDocSections = Set(collapsedLayoutSections.map(\.rawValue))
        return OrderSource(top: top, inBlock: inBlock, listed: listed, options: options)
    }

    /// The list's selectable rows in drawn order, and the stop that stands for each collapsed group's members.
    private func orderRows(_ source: OrderSource) -> (rows: [SidebarItem], stops: [WorkspaceID: SidebarItem]) {
        let selectable = Set(selectableWorkspaces.map(\.id))
        var rows: [SidebarItem] = []
        var stops: [WorkspaceID: SidebarItem] = [:]
        for row in SidebarLayout.make(sections: sections, metrics: .standard, options: source.options).rows {
            switch row.key {
            case let .workspace(id) where selectable.contains(id):
                rows.append(.workspace(id))
            case let .item(id):
                rows.append(.topItem(LayoutItemID(id))) // a link, tab or app row is a stop like a band item
            case let .block(id) where !collapsedLayoutSections.contains(LayoutSectionID(id)):
                rows += (source.inBlock[id] ?? []).map { .topItem($0.id) }
            case let .group(id):
                guard let group = group(id), group.isCollapsed else { continue }
                let members = group.workspaces.map(\.id).filter(selectable.contains)
                guard !members.isEmpty else { continue }
                rows.append(.group(id))
                for member in members { stops[member] = .group(id) }
            default:
                continue
            }
        }
        return (rows, stops)
    }
}

/// Everything `itemOrder` reads. Row content patches (status, title) keep
/// `sectionsRevision`, and they move no row while no filter is set (with a
/// filter a patch is a structural set), so the revision stands for the rows.
/// Unchanged values compare by storage identity, so a hit is O(1).
nonisolated struct SidebarItemOrderInputs: Equatable, Sendable {
    var sectionsRevision: UInt64
    var filterText: String
    var layout: SidebarLayoutDocument
    var itemInfo: [LayoutItemID: SidebarItemInfo]
    var room: ProfileKey?
    var suppressedApps: Set<String>
    var transientTopItems: [SidebarTransientItem]
    var grouping: SidebarGrouping
    var collapsedLayoutSections: Set<LayoutSectionID>
    var rowLimit: Int
    var openDoneFolds: Set<SidebarDoneFoldID>
    var openShowMore: Set<SidebarDoneFoldID>
    var treeShape: SidebarSessionTreeState?

    @MainActor init(_ model: SidebarModel) {
        sectionsRevision = model.observedSectionsRevision
        filterText = model.filterText
        layout = model.layout
        itemInfo = model.itemInfo
        room = model.activeProfileID
        suppressedApps = model.suppressedApps
        transientTopItems = model.transientTopItems
        grouping = model.grouping
        collapsedLayoutSections = model.collapsedLayoutSections
        rowLimit = SidebarTunables.rowLimit
        (openDoneFolds, openShowMore) = (model.openDoneFolds, model.openShowMore)
        treeShape = SidebarSessionTree.shared.drawn?.shape
    }
}
