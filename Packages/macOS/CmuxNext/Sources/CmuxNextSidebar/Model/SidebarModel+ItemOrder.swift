extension SidebarModel {
    /// This sidebar's destinations in shown order (``SidebarItemOrder``): the
    /// top region's visible items (hidden, missing and suppressed apps' items
    /// skipped), then the list's selectable rows in drawn order (the sidebar's
    /// own row layout, so collapsed sections and rows the filter hides are not
    /// stops). A collapsed group is one stop; an empty one is none.
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
        var options = SidebarLayoutOptions()
        options.filterMatches = filterMatches
        options.grouping = settledGrouping()
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
        return SidebarItemOrder(topItems: topItems.map { .topItem($0.id) }, rows: rows, stops: stops)
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
        treeShape = SidebarSessionTree.shared.drawn?.shape
    }
}
