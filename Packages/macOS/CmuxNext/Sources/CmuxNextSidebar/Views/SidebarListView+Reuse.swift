import AppKit
// Row view reuse through `rowPool`: views exist only for rows near the
// viewport, and leaving rows return to the pool.
extension SidebarListViewComponents {
    /// `rebinding`: with no parked view of `key`, take another parked row's
    /// view of the same kind (scroll realization only: the view is placed,
    /// never animated, so nothing flies in from its old row, cx-ai79).
    func dequeue(_ key: SidebarRowKey, rebinding: Bool = false) -> SidebarRowView {
        let view = rowPool.take(for: key, rebinding: rebinding)
        view.isHidden = false
        wire(view, key: key)
        return view
    }
    /// A row view that leaves the list parks hidden in place: taking it out of the window and adding
    /// it back on each scroll realization re-registered its controls' constraints and window state
    /// (16% of the main thread while scrolling 1,000 rows, perf round 2). A view in another superview
    /// (a lift) leaves it, and a view the pool evicts leaves the list.
    func recycle(_ view: SidebarRowView) {
        // Invalidate before stopping springs: their completion may still arrive after this view is reused.
        view.reuseGeneration &+= 1
        view.closingEnd = nil
        fadingRows[ObjectIdentifier(view)] = nil
        // A parked view must not retain a render-server move from the list it just left. In
        // particular, a non-animated reload removes a row by recycling it directly, without
        // passing it through RowMotion.run's stop set; leaving its additive spring active would
        // keep the hidden row in the next layout's motion probe and on a later dequeue.
        SidebarDragSpring.stop([view])
        if view.key == hoveredKey {
            hoveredKey = nil
            view.clearHoverImmediately()
        }
        if view.superview === self { view.isHidden = true } else { view.removeFromSuperview() }
        for evicted in rowPool.put(view) where evicted.superview === self { evicted.removeFromSuperview() }
    }
    /// A close owns only the lifetime it started in; a calm reload can already have reused its view.
    func finishLeaving(_ view: SidebarRowView, generation: Int) {
        guard view.reuseGeneration == generation else { return }
        fadingRows[ObjectIdentifier(view)] = nil
        guard !rowViews.values.contains(where: { $0 === view }) else { return }
        recycle(view)
    }
    /// Per-key callbacks, set on every dequeue so recycled views never keep
    /// a previous row's target.
    func wire(_ view: SidebarRowView, key: SidebarRowKey) {
        switch (key, view) {
        case let (.workspace(id), view as WorkspaceRowView):
            view.wire(id, in: self)
        case let (.item(id), view as SidebarItemListRowView):
            // A link, tab or app row runs as the band's item does (AXPress too).
            view.onSelect = { [weak self] in self?.model.send(.activateItem(LayoutItemID(id))) }
        case (.block, let view as SidebarBlockRowView):
            // On every dequeue: a parked block comes back in the sidebar's state now (its edit mode).
            view.region.docList = self
            configureBlockRegion?(view.region)
        case let (.group(id), view as GroupHeaderRowView) where SidebarGroup.hostMachine(id) != nil:
            // A remote group: its more button shows the machine's menu (no group editor: it has no name or color of
            // its own), and its + makes a workspace on the machine, as the machine header's did.
            let machine = SidebarGroup.hostMachine(id)
            view.onMore = { [weak self] in self?.groupEditing.showMenu(id) }
            view.onEdit = view.onMore
            view.onAdd = { [weak self] in self?.model.send(.newWorkspace(machine: machine, group: nil)) }
            view.isEditing = false
            view.isKeyboardFocused = showsFocusRing && focusedGroup == id
        case let (.group(id), view as GroupHeaderRowView):
            view.onMore = { [weak self] in self?.groupEditing.showMenu(id) } // VoiceOver's full menu; the chip and more button edit
            view.onEdit = { [weak self] in self?.groupEditing.open(id, from: .moreButton) }
            // The header's + runs the editor's New Workspace in Group (one action path).
            view.onAdd = onGroupEditorItem == nil ? nil : { [weak self] in self?.onGroupEditorItem?(id, "workspaceGroup.newWorkspace") }
            view.isEditing = groupEditor.shownGroup == id
            view.isKeyboardFocused = showsFocusRing && focusedGroup == id
        case let (.emptyGroup(id), view as EmptyGroupRowView):
            // The same New Workspace in Group as the header's + (one action path).
            view.onAdd = onGroupEditorItem == nil ? nil : { [weak self] in self?.onGroupEditorItem?(id, "workspaceGroup.newWorkspace") }
        case (.doneFold, let view as SidebarDoneFoldRowView), (.showMore, let view as SidebarDoneFoldRowView):
            view.onToggle = { [weak self] in
                guard let self else { return false }
                return SidebarFoldAction(list: self).toggle(key)
            }
        case let (.section(sectionID), view as SectionHeaderRowView):
            if case let .machine(machine) = sectionID {
                view.allowsAdd = true
                view.onAdd = { [weak self] in self?.model.send(.newWorkspace(machine: machine, group: nil)) }
            } else {
                view.allowsAdd = false
                view.onAdd = nil
            }
        default:
            break
        }
    }
}
