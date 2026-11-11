import AppKit

// A space shown again shows the rows it had (Lawrence 2026-11-10: a press on a space "instantly switches"). The list
// laid out every row of a space on each switch (`SidebarLayout.make`), also on a switch back to a space whose rows did
// not change: work that grows with the space, in the turn of the key.
//
// Chromium does not lay a tab out again when it shows it again: the browser keeps each tab's contents and swaps the
// shown one in (`BrowserView::OnActiveTabChanged`, chrome/browser/ui/views/frame/browser_view.cc), and Blink takes a
// box's layout result from its cache when the inputs of the layout did not change (`LayoutBox::CachedLayoutResult`,
// third_party/blink/renderer/core/layout/layout_box.cc). The same here: a layout is a function of the sections, the
// metrics and the options (`SidebarLayout.make`), so the list keeps the layout of each space the person left, with
// those inputs, and shows it again while the inputs are the same. A row whose content changed while its space was
// hidden is patched in the kept layout, as a row of the shown space is (`patchRowsNow`). Any other change, and any
// doubt, lays the space out in full as before.

/// One space as the list drew it when the person left it: its full layout and what that is the layout of.
struct SidebarSpacePage {
    /// The sections `layout` is the full layout of, in the model's order, as the list's row caches held them (each
    /// row patch since the layout is in them).
    var sections: [SidebarSection]
    var layout: SidebarLayout
    var options: SidebarLayoutOptions
    var metrics: SidebarLayoutMetrics
    /// The list's row caches for `layout` (`SidebarListView.rebuildRowCaches`).
    var workspaces: [WorkspaceID: SidebarWorkspace]
    var groups: [GroupID: SidebarGroup]
    var groupSubtrees: [GroupID: [GroupID]]
    var sectionsByID: [SectionID: SidebarSection]
    var listItems: [String: SidebarListItem]

    /// Whether the full layout under `now` is the kept one: the same options, apart from an active workspace whose
    /// selection moves no row.
    func shows(_ now: SidebarLayoutOptions) -> Bool {
        var (kept, shown) = (options, now)
        (kept.activeWorkspaceID, shown.activeWorkspaceID) = (nil, nil)
        guard kept == shown else { return false }
        guard options.activeWorkspaceID != now.activeWorkspaceID else { return true }
        // "Show N more" and Recents choose their rows by the active one.
        guard now.rowLimit == 0, !SidebarLayout.drawsRecents(now) else { return false }
        return keepsRows(selecting: options.activeWorkspaceID, now) && keepsRows(selecting: now.activeWorkspaceID, now)
    }

    /// Whether workspace `id` draws the same rows active or not: the rule of the list's splices
    /// (`SidebarListView.keepsRows(selecting:inserted:_:)`) on the page's rows. An archived or a Done row, a row a
    /// collapsed group or a fold hides, and a row of a group that leaves for the Archive are drawn only while active.
    private func keepsRows(selecting id: WorkspaceID?, _ o: SidebarLayoutOptions) -> Bool {
        guard let id, let ws = workspaces[id] else { return true }
        guard !ws.isArchived, !(o.foldsDone && ws.taskStatus == .done) else { return false }
        guard let row = layout.row(for: .workspace(id)) else { return false }
        var group = row.group
        var seen: Set<GroupID> = []
        while let id = group, seen.insert(id).inserted {
            guard let listed = groups[id], !listed.isCollapsed, !listed.isArchived,
                  listed.workspaces.isEmpty || !listed.workspaces.allSatisfy(\.isArchived) else { return false }
            group = listed.parent
        }
        return true
    }

    /// Whether `change`'s row is the one member of its group: a new title may then change the group's rows (one row
    /// in the header's place, or a header over a member row, `SidebarLayout+SoleMember`).
    func isSoleMember(_ change: SidebarRowContentChange) -> Bool {
        guard change.path.member != nil, case let .group(group) = sections[change.path.section].nodes[change.path.node] else { return false }
        return group.members.count == 1
    }

    /// The groups the sections list, each once, in the order the sections list them.
    var orderedGroups: [SidebarGroup] {
        var ordered: [SidebarGroup] = []
        var seen: Set<GroupID> = []
        for section in sections {
            for case let .group(group) in section.nodes where seen.insert(group.id).inserted { ordered.append(group) }
        }
        return ordered
    }
}

/// The pages of the spaces the person left (`SidebarSpacePage`), one per space the model still has.
struct SidebarSpacePages {
    private var kept: [ProfileKey: SidebarSpacePage] = [:]
    /// The space the reload that runs now shows (`SidebarListView.showSpace`); nil outside a space switch.
    var entering: ProfileKey?
    /// Rows of the page taken for `entering` whose content changed while the space was hidden: patched after the apply.
    var changedRows: [SidebarWorkspace] = []
    /// The metrics of the full layout the list shows (`SidebarListView.spliceBase`), read when it was made: the list's
    /// own `metrics` are the tokens of now, which a density or a font change in the turn of a switch already moved.
    /// Nil when the list shows no full layout of its row caches: no page is kept from it (`spacePage`).
    private(set) var shownMetrics: SidebarLayoutMetrics?
    /// The model's structure (`SidebarModel.structureRevision`) that full layout was made of.
    private var shownStructure: UInt64 = 0

    /// The list shows a full layout made with `metrics` of the model at `structure` (nil: it shows no full layout).
    mutating func showsFullLayout(metrics: SidebarLayoutMetrics?, structure: UInt64) {
        (shownMetrics, shownStructure) = (metrics, structure)
    }

    /// The list's row caches take a change of the model in place (a row patch, a group's fold) with the model at
    /// `structure`. When that is not the structure the shown layout was made of (a set whose reload has not run),
    /// the caches are ahead of the layout: no page is kept from them until the next full layout.
    mutating func cachesTookChange(at structure: UInt64) {
        if structure != shownStructure { shownMetrics = nil }
    }

    /// Keeps `page` (nil: nothing to keep) for `space`, and drops the pages of spaces the model no longer has.
    mutating func keep(_ page: SidebarSpacePage?, for space: ProfileKey, live: Set<ProfileKey>) {
        kept = kept.filter { live.contains($0.key) }
        kept[space] = live.contains(space) ? page : nil
    }

    /// The page of `space`, taken out: the list shows that space now and keeps a new page when the person leaves it.
    mutating func take(_ space: ProfileKey) -> SidebarSpacePage? { kept.removeValue(forKey: space) }
}

extension SidebarListViewComponents {
    /// Shows the model's rows after a space switch from `left` to `shown` (`SidebarView.showSpace`), with no motion:
    /// the space the list leaves is kept as a page, and a space shown again takes its page (`takeSpacePage`).
    func showSpace(leaving left: ProfileKey?, entering shown: ProfileKey?) {
        if let left { spacePages.keep(spacePage(), for: left, live: Set(model.profiles.map(\.id))) }
        spacePages.entering = shown
        reload(animated: false)
        spacePages.entering = nil
        let changed = spacePages.changedRows
        guard !changed.isEmpty else { return }
        spacePages.changedRows = []
        SidebarPerfCounters.add(.rowPatches, changed.count)
        // A row's height changed while its space was hidden: the full layout, in this turn (the frame of the switch
        // shows the space complete; it does not wait for the pointer to leave the rows).
        if SidebarPerfCounters.timed({ patchRowsNow(changed) }) {
            spliceBase = nil
            reload(animated: false)
        }
    }

    /// The space the list shows as a page: only a full layout of the model (`spliceBase`) at rest, with no change
    /// held and no drag, so the layout is the one a reload would make of the caches' sections. Each change of the
    /// layout in place writes the caches too: a row patch its row (`patchRowsNow`), a fold its section (`foldGroup`).
    /// A patch or a fold that comes after a structural set the list has not shown yet writes caches that are ahead of
    /// the layout (`SidebarSpacePages.cachesTookChange`): the list then keeps no page until its next full layout.
    private func spacePage() -> SidebarSpacePage? {
        guard let base = spliceBase, let metrics = spacePages.shownMetrics, !holdsModelChange, drag == nil, settling == nil,
              landing == nil, external == nil, rowHold.isEmpty, leaving.isEmpty, !displayed.rows.isEmpty,
              appliedSections.count == sections.count else { return nil }
        var ordered: [SidebarSection] = []
        ordered.reserveCapacity(appliedSections.count)
        for section in appliedSections {
            guard let listed = sections[section.id] else { return nil }
            ordered.append(listed)
        }
        return SidebarSpacePage(sections: ordered, layout: displayed, options: base.options, metrics: metrics, workspaces: workspaces,
                                groups: groups, groupSubtrees: groupSubtrees, sectionsByID: sections, listItems: listItems)
    }

    /// The kept layout of the space this reload shows, with the options it is the full layout of, when the model's
    /// rows are the page's: the page's row caches become the list's and no row is laid out. Rows whose content
    /// changed while the space was hidden keep their places and are patched after the apply (`showSpace`). Nil, with
    /// the caches as they were, for any other change (a row added, removed or moved, a group folded or opened while
    /// the space was hidden, a filter, other options or metrics, a content change that moves rows) and for any
    /// doubt: the reload then lays the space out in full.
    func takeSpacePage() -> (layout: SidebarLayout, options: SidebarLayoutOptions)? {
        guard let space = spacePages.entering, let page = spacePages.take(space) else { return nil }
        guard drag == nil, settling == nil, landing == nil, external == nil, rowHold.isEmpty, leaving.isEmpty,
              model.filterText.isEmpty, metrics == page.metrics else { return nil }
        let now = options(includeGap: true)
        // One compare per row of the space, no layout (the compare the model's own row patch path makes).
        guard page.shows(now), let changes = SidebarSection.rowContentChanges(from: page.sections, to: model.sections) else { return nil }
        if !changes.isEmpty {
            // Group by Status, Recents and the session tree place rows by their content with state of their own.
            guard !model.groupsByStatus, !model.grouping.groupsByRecents, SidebarSessionTree.shared.drawn == nil else { return nil }
            for change in changes {
                guard model.listedPaths(of: change.new.id).count == 1,
                      !SidebarModel.movesRows(from: change.old, to: change.new, groupsByFolder: model.groupsByFolder),
                      change.old.title == change.new.title || !page.isSoleMember(change) else { return nil }
            }
        }
        (workspaces, groups, groupSubtrees, sections, listItems) = (page.workspaces, page.groups, page.groupSubtrees, page.sectionsByID, page.listItems)
        setDrawnTints(page.orderedGroups)
        spacePages.changedRows = changes.map(\.new)
        return (page.layout, now)
    }
}
