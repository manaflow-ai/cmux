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

    private func makeItemOrder() -> SidebarItemOrder {
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
        let selectable = Set(selectableWorkspaces.map(\.id))
        var rows: [SidebarItem] = []
        var stops: [WorkspaceID: SidebarItem] = [:]
        for row in SidebarLayout.make(sections: sections, metrics: .standard, options: options).rows {
            switch row.key {
            case let .workspace(id) where selectable.contains(id):
                rows.append(.workspace(id))
            case let .item(id):
                rows.append(.topItem(LayoutItemID(id))) // a link, tab or app row is a stop like a band item
            case let .block(id) where !collapsedLayoutSections.contains(LayoutSectionID(id)):
                rows += (inBlock[id] ?? []).map { .topItem($0.id) }
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
        let topItems = top.filter { item in !listed.contains(inBlock.first { $0.value.contains(item) }?.key ?? "") }
        return SidebarItemOrder(topItems: topItems.map { .topItem($0.id) }, rows: rows, stops: stops,
                                places: places(rows: rows, stops: stops, inBlock: inBlock, options: options))
    }

    /// Where each workspace that draws away from its stop when selected sits among `rows`: one folded into "Done (N)"
    /// or behind "Show N more" (no stop), or one an opened fold lists at the end of its list (its stop is there, but
    /// selected it draws in its place). The index is after the last stop drawn before it with the folds off, the order
    /// rows draw in when selected, items (links, tabs, apps) and sorts included; a row that layout does not draw either
    /// goes after the last stop before it in the model's order. Selected, it draws there, so stepping goes on from
    /// there. Lays the list out a second time only when some workspace needs a place.
    private func places(rows: [SidebarItem], stops: [WorkspaceID: SidebarItem], inBlock: [String: [LayoutItem]],
                        options o: SidebarLayoutOptions) -> [WorkspaceID: Int] {
        var index: [SidebarItem: Int] = [:]
        for (i, item) in rows.enumerated() where index[item] == nil { index[item] = i }
        var placed: Set<WorkspaceID> = []
        for ws in selectableWorkspaces where stops[ws.id] == nil {
            let folds = ws.isArchived || (o.foldsDone && ws.taskStatus == .done)
            if index[.workspace(ws.id)] == nil || folds { placed.insert(ws.id) }
        }
        guard !placed.isEmpty else { return [:] }
        var unfolded = o
        // A selected Done or archived row keeps its place in its list (`foldingDone`, `splittingArchive`).
        (unfolded.foldsDone, unfolded.foldsArchived, unfolded.archiveSection, unfolded.rowLimit) = (false, false, false, 0)
        var next = 0
        var places: [WorkspaceID: Int] = [:]
        for row in SidebarLayout.make(sections: sections, metrics: .standard, options: unfolded).rows {
            switch row.key {
            case let .workspace(id) where placed.contains(id):
                // Drawn where it would draw selected (a filter or Group by Status folds nothing): its own row is its
                // stop, as any other row's. Else it draws away from there: step from its place.
                if let at = index[.workspace(id)], at == next { next = at + 1 } else { places[id] = next }
            case let .workspace(id):
                if let at = index[.workspace(id)] { next = at + 1 }
            case let .item(id):
                if let at = index[.topItem(LayoutItemID(id))] { next = at + 1 }
            case let .block(id):
                if let at = (inBlock[id] ?? []).compactMap({ index[.topItem($0.id)] }).max() { next = at + 1 }
            case let .group(id):
                if let at = index[.group(id)] { next = at + 1 }
            default:
                continue
            }
        }
        // A row even that layout does not draw (a subgroup under a collapsed parent): after the last stop before it
        // in the model's order.
        let unplaced = placed.filter { places[$0] == nil && index[.workspace($0)] == nil }
        guard !unplaced.isEmpty else { return places }
        next = rows.firstIndex { if case .topItem = $0 { false } else { true } } ?? rows.count
        for ws in selectableWorkspaces {
            if unplaced.contains(ws.id) {
                places[ws.id] = next
            } else if let at = index[.workspace(ws.id)] ?? stops[ws.id].flatMap({ index[$0] }) {
                next = at + 1
            }
        }
        return places
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
