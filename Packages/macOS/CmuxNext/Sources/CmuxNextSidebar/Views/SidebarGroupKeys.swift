import AppKit

/// Keyboard on group headers (cx-qno.17). Up/Down walk every visible stop:
/// group headers, disclosure rows and workspace rows in drawn order (a collapsed group is its
/// header alone). A header takes keyboard focus, never the selection
/// (SIDEBAR-SELECTION-ONE-MODEL); a workspace stop selects and activates it.
/// Left on a member goes to its header, Left on an open header collapses
/// it; Right opens a closed header, then enters its first member; Return on
/// a focused header renames the group. Tab moves focus into and between
/// the group headers and disclosures (Shift-Tab back, to the workspaces before the first);
/// Space on a focused header toggles it as a click on its bar does. A
/// namespace beside the list (not an extension) keeps the list type under
/// the god-file limit.
@MainActor struct SidebarGroupKeys {
    enum Stop: Equatable {
        case group(GroupID)
        case workspace(WorkspaceID)
        case fold(SidebarRowKey)
    }

    let list: SidebarListView
    private var model: SidebarModel { list.model }

    /// The visible keyboard stops in drawn order. A group drawn as its one row (`SidebarLayout+SoleMember`) has that
    /// row for its header: two stops, the group's (the row draws its focus ring) and then its member's, as a header
    /// and its first member are, so every key on a focused group works there as on a header.
    var stops: [Stop] {
        list.displayed.rows.flatMap { row -> [Stop] in
            switch row.key {
            case let .group(group): return [.group(group)]
            case let .workspace(id):
                guard !model.isPlaceholder(id) else { return [] }
                guard row.standsForGroup, let group = row.group else { return [.workspace(id)] }
                return [.group(group), .workspace(id)]
            case .doneFold, .showMore: return [.fold(row.key)]
            default: return []
            }
        }
    }

    /// Handles a plain arrow, Return, Tab or Space for group headers, and
    /// Shift-Tab (`flags`: the event's command, option, shift and control).
    /// False leaves the key to the workspace-only behavior and the window.
    func handle(_ event: NSEvent, flags: NSEvent.ModifierFlags) -> Bool {
        if let key = list.focusedFold, list.displayed.row(for: key) == nil { setFocus(nil) }
        if event.specialKey == .backTab || event.specialKey == .tab, flags == .shift { return tab(forward: false) }
        guard flags.isEmpty else { return false }
        if event.keyCode == 49 { return space() } // Space
        switch event.specialKey {
        case .tab?:
            return tab(forward: true)
        case .upArrow?, .downArrow?:
            let stops = stops
            let current = currentStop
            guard let current, let index = stops.firstIndex(of: current) else {
                setFocus(nil)
                return false
            }
            let next = index + (event.specialKey == .upArrow ? -1 : 1)
            // Past the first or last stop, focus moves on to the items around the list (cx-qno.10).
            if stops.indices.contains(next) {
                focus(stops[next])
            } else if SidebarArrowWalk.leave(list, up: next < 0) {
                setFocus(nil)
            }
            return true
        case .leftArrow?:
            if let key = list.focusedFold { return setFold(key, collapsed: true) }
            if let group = list.focusedGroup {
                if model.group(group)?.isCollapsed == false { toggle(group) }
                return true
            }
            guard let active = model.activeWorkspaceID, let group = group(containing: active) else { return false }
            focus(.group(group))
            return true
        case .rightArrow?:
            if let key = list.focusedFold { return setFold(key, collapsed: false) }
            guard let id = list.focusedGroup, let group = model.group(id) else { return false }
            if group.isCollapsed {
                toggle(id)
            } else if let first = group.workspaces.first(where: { !model.isPlaceholder($0.id) }) {
                focus(.workspace(first.id))
            }
            return true
        case .carriageReturn?, .enter?:
            if let key = list.focusedFold { return SidebarFoldAction(list: list).toggle(key) }
            guard let group = list.focusedGroup else { return false }
            list.groupEditing.open(group)
            return true
        default:
            return false
        }
    }

    private var currentStop: Stop? {
        list.focusedFold.map(Stop.fold) ?? list.focusedGroup.map(Stop.group) ?? model.activeWorkspaceID.map(Stop.workspace)
    }

    private func setFold(_ key: SidebarRowKey, collapsed: Bool) -> Bool {
        guard let row = list.displayed.row(for: key) else { return false }
        return row.isCollapsed == collapsed || SidebarFoldAction(list: list).toggle(key)
    }

    func focus(_ stop: Stop) {
        switch stop {
        case let .group(group):
            setFocus(group)
        case let .fold(key):
            focusFold(key, ring: true)
        case let .workspace(id):
            setFocus(nil)
            model.activeWorkspaceID = id
            model.click(id)
        }
        list.reload(animated: true)
        if case let .fold(key) = stop, let row = list.displayed.row(for: key) {
            list.scrollToVisible(list.frame(for: row))
        }
    }

    /// Moves keyboard focus to the disclosure `key`, with its ring when the keyboard moved it (`ring`); a click
    /// focuses it without one, so Space, Return and the arrows continue from the row clicked last.
    func focusFold(_ key: SidebarRowKey, ring: Bool) {
        setFocus(nil)
        list.focusedFold = key
        list.showsFocusRing = ring
        (list.rowViews[key] as? SidebarDoneFoldRowView)?.isKeyboardFocused = ring
    }

    /// Moves keyboard focus to `group` (nil: back to the workspaces) and
    /// draws the ring on its header when the keyboard moved it (`ring`); a
    /// mouse click sets the focus without a ring.
    func setFocus(_ group: GroupID?, ring: Bool = true) {
        if let key = list.focusedFold {
            (list.rowViews[key] as? SidebarDoneFoldRowView)?.isKeyboardFocused = false
        }
        list.focusedFold = nil
        let old = list.focusedGroup
        list.focusedGroup = group
        // Kept on the list, not only on the view: a header view made later
        // (reuse, scrolling, a reload that dropped it) draws the ring too.
        list.showsFocusRing = ring && group != nil
        for key in [old, group].compactMap({ $0 }) {
            let ringed = list.showsFocusRing && key == group
            // The header, or the one row a group draws as (`SidebarListView.configure` rings it on a reload too).
            switch list.displayed.groupRow(key).flatMap({ list.rowViews[$0.key] }) {
            case let header as GroupHeaderRowView: header.isKeyboardFocused = ringed
            case let row as WorkspaceRowView: row.isKeyboardFocused = ringed
            default: break
            }
        }
    }

    /// Tab: the next group header or disclosure (the first from the workspaces); past
    /// the last one focus goes back to the workspaces and the window's key
    /// loop moves on. Shift-Tab: the previous header; before the first, the
    /// workspaces. False when the key is not the list's.
    private func tab(forward: Bool) -> Bool {
        let headers = stops.filter { if case .workspace = $0 { false } else { true } }
        guard let current = currentStop, let index = headers.firstIndex(of: current) else {
            guard forward, let first = headers.first else { return false }
            focus(first)
            return true
        }
        let next = index + (forward ? 1 : -1)
        if headers.indices.contains(next) {
            focus(headers[next])
            return true
        }
        setFocus(nil)
        list.reload(animated: true)
        return !forward
    }

    /// Space on a focused header: what a click on its bar does (an empty
    /// saved group reopens, any other group folds or opens).
    private func space() -> Bool {
        if let key = list.focusedFold { return SidebarFoldAction(list: list).toggle(key) }
        // Only a header the keyboard focused (ring shown): a click focuses
        // without a ring and already toggled.
        guard let id = list.focusedGroup, list.showsFocusRing else { return false }
        if let group = model.group(id), group.isPinned, group.workspaces.isEmpty, group.items.isEmpty {
            model.send(.openGroup(id))
            list.reload(animated: true)
        } else {
            toggle(id)
        }
        return true
    }

    private func toggle(_ group: GroupID) {
        // The fold draws itself on the group's rows (`SidebarListView.foldGroup`): no list reload.
        model.noteUserIntent()
        model.send(.toggleCollapse(.group(group)))
    }

    private func group(containing id: WorkspaceID) -> GroupID? {
        for section in model.sections {
            for case let .group(group) in section.nodes where group.workspaces.contains(where: { $0.id == id }) {
                return group.id
            }
        }
        return nil
    }
}
