import AppKit

/// Keyboard on group headers (cx-qno.17). Up/Down walk every visible stop:
/// group headers and workspace rows in drawn order (a collapsed group is its
/// header alone). A header takes keyboard focus, never the selection
/// (SIDEBAR-SELECTION-ONE-MODEL); a workspace stop selects and activates it.
/// Left on a member goes to its header, Left on an open header collapses
/// it; Right opens a closed header, then enters its first member; Return on
/// a focused header renames the group. Tab moves focus into and between
/// the group headers (Shift-Tab back, to the workspaces before the first);
/// Space on a focused header toggles it as a click on its bar does. A
/// namespace beside the list (not an extension) keeps the list type under
/// the god-file limit.
@MainActor struct SidebarGroupKeys {
    enum Stop: Equatable {
        case group(GroupID)
        case workspace(WorkspaceID)
    }

    let list: SidebarListView
    private var model: SidebarModel { list.model }

    /// The visible keyboard stops in drawn order.
    var stops: [Stop] {
        list.displayed.rows.compactMap { row in
            switch row.key {
            case let .group(group): .group(group)
            case let .workspace(id): model.isPlaceholder(id) ? nil : .workspace(id)
            default: nil
            }
        }
    }

    /// Handles a plain arrow, Return, Tab or Space for group headers, and
    /// Shift-Tab (`flags`: the event's command, option, shift and control).
    /// False leaves the key to the workspace-only behavior and the window.
    func handle(_ event: NSEvent, flags: NSEvent.ModifierFlags) -> Bool {
        if event.specialKey == .backTab || (event.specialKey == .tab && flags == .shift) { return tab(forward: false) }
        guard flags.isEmpty else { return false }
        if event.keyCode == 49 { return space() } // Space
        switch event.specialKey {
        case .tab?:
            return tab(forward: true)
        case .upArrow?, .downArrow?:
            let stops = stops
            let current = list.focusedGroup.map(Stop.group) ?? model.activeWorkspaceID.map(Stop.workspace)
            guard let current, let index = stops.firstIndex(of: current) else {
                setFocus(nil)
                return false
            }
            let next = index + (event.specialKey == .upArrow ? -1 : 1)
            if stops.indices.contains(next) { focus(stops[next]) }
            return true
        case .leftArrow?:
            if let group = list.focusedGroup {
                if model.group(group)?.isCollapsed == false { toggle(group) }
                return true
            }
            guard let active = model.activeWorkspaceID, let group = group(containing: active) else { return false }
            focus(.group(group))
            return true
        case .rightArrow?:
            guard let id = list.focusedGroup, let group = model.group(id) else { return false }
            if group.isCollapsed {
                toggle(id)
            } else if let first = group.workspaces.first(where: { !model.isPlaceholder($0.id) }) {
                focus(.workspace(first.id))
            }
            return true
        case .carriageReturn?, .enter?:
            guard let group = list.focusedGroup else { return false }
            list.groupEditing.open(group)
            return true
        default:
            return false
        }
    }

    func focus(_ stop: Stop) {
        switch stop {
        case let .group(group):
            setFocus(group)
        case let .workspace(id):
            setFocus(nil)
            model.activeWorkspaceID = id
            model.click(id)
        }
        list.reload(animated: true)
    }

    /// Moves keyboard focus to `group` (nil: back to the workspaces) and
    /// draws the ring on its header when the keyboard moved it (`ring`); a
    /// mouse click sets the focus without a ring.
    func setFocus(_ group: GroupID?, ring: Bool = true) {
        let old = list.focusedGroup
        list.focusedGroup = group
        // Kept on the list, not only on the view: a header view made later
        // (reuse, scrolling, a reload that dropped it) draws the ring too.
        list.showsFocusRing = ring && group != nil
        for key in [old, group].compactMap({ $0 }) {
            (list.rowViews[.group(key)] as? GroupHeaderRowView)?.isKeyboardFocused = list.showsFocusRing && key == group
        }
    }

    /// Tab: the next group header (the first from the workspaces); past
    /// the last one focus goes back to the workspaces and the window's key
    /// loop moves on. Shift-Tab: the previous header; before the first, the
    /// workspaces. False when the key is not the list's.
    private func tab(forward: Bool) -> Bool {
        let headers = stops.compactMap { if case let .group(group) = $0 { group } else { nil } }
        guard let current = list.focusedGroup, let index = headers.firstIndex(of: current) else {
            guard forward, let first = headers.first else { return false }
            focus(.group(first))
            return true
        }
        let next = index + (forward ? 1 : -1)
        if headers.indices.contains(next) {
            focus(.group(headers[next]))
            return true
        }
        setFocus(nil)
        list.reload(animated: true)
        return !forward
    }

    /// Space on a focused header: what a click on its bar does (an empty
    /// saved group reopens, any other group folds or opens).
    private func space() -> Bool {
        guard let id = list.focusedGroup else { return false }
        if let group = model.group(id), group.isPinned, group.workspaces.isEmpty {
            model.send(.openGroup(id))
            list.reload(animated: true)
        } else {
            toggle(id)
        }
        return true
    }

    private func toggle(_ group: GroupID) {
        model.send(.toggleCollapse(.group(group)))
        list.reload(animated: true)
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
