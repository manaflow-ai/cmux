public import AppKit
public import CmuxNextDesign
public import CmuxNextResources
// The list's targets for the app's hover cards (WorkspaceHoverCardController,
// HoverCardCoordinator): workspace rows, hit-tested by position.
extension SidebarListViewComponents {
    /// The coordinator this list reports to (the App injects the app's one).
    public var hoverCards: HoverCardCoordinator {
        get { hoverCard.coordinator }
        set { hoverCard.coordinator = newValue }
    }
    /// Shows workspace `id`'s card now (the "Show Resource Usage" action),
    /// scrolling its row into view first.
    @discardableResult
    func showHoverCard(for id: WorkspaceID) -> Bool {
        guard let window else { return false }
        if workspaces[id] != nil, let row = displayed.row(for: .workspace(id)) {
            scrollToVisible(frame(for: row))
        } else if let pinned = blockItemView(for: id) {
            // A pinned workspace's row (a block item) shows the same card.
            scrollToVisible(convert(pinned.bounds, from: pinned))
        } else {
            return false
        }
        let target = HoverTarget(id: WorkspaceHoverCardController.targetID(id), window: window.windowNumber, delay: hoverCard.delay)
        // The action asks for resource usage, which lives in the card's details.
        hoverCard.requestDetails(for: id)
        hoverCards.pin(target, from: hoverCard)
        return hoverCards.isShowing(target.id)
    }
    /// The workspace row `point` (this view's coordinates) hovers, by the
    /// list's own hover rule, that may have a card now: none during a drag or rename, or off the visible rows.
    /// A pinned workspace's row (an item of a block, `blockWorkspace(at:)`) has the same card.
    func hoverCardWorkspace(at point: CGPoint) -> WorkspaceID? {
        guard drag == nil, !inlineRename.isActive, visibleRect.contains(point), !isHiddenOrHasHiddenAncestor else { return nil }
        // The list's own rows (a dictionary): `model.isPlaceholder` walks every section, and this
        // runs on each scroll frame (hover geometry), O(workspaces) per frame at 1,000 rows.
        switch hoverHit(at: point)?.key {
        case .workspace(let id)?:
            guard let row = workspaces[id], !row.rowState.isPending else { return nil }
            return id
        case .block?:
            return blockWorkspace(at: point)
        default:
            return nil
        }
    }
    /// The group header under `point` that may have a summary card now
    /// (`sidebar.hoverCards.groups.workspaceGroups`): none during a drag, a rename or an open group
    /// editor. One row lookup by position, like a workspace row's: a hover never walks the groups.
    func hoverCardGroup(at point: CGPoint) -> GroupID? {
        guard DesignSettings.shared.groupHoverCard.workspaceGroups, drag == nil, !inlineRename.isActive,
              visibleRect.contains(point), !isHiddenOrHasHiddenAncestor,
              case .group(let id)? = displayed.row(at: point.y)?.key, groups[id] != nil, !isEmptyTree(id) else { return nil }
        return id
    }
    /// The workspaces in `id` and every group under it, in document order: the group's card counts them.
    func subtreeWorkspaces(of id: GroupID) -> [SidebarWorkspace] {
        (groupSubtrees[id] ?? [id]).flatMap { groups[$0]?.workspaces ?? [] }
    }
    /// No workspace in `id` nor under it: its card, which counts workspaces, would say nothing.
    private func isEmptyTree(_ id: GroupID) -> Bool {
        (groupSubtrees[id] ?? [id]).allSatisfy { groups[$0]?.workspaces.isEmpty ?? true }
    }
    /// The group's row on screen (its header, or the one row it draws as), nil when it is not laid out.
    func hoverCardAnchor(forGroup id: GroupID) -> CGRect? {
        guard let window, let row = displayed.groupRow(id) else { return nil }
        return window.convertToScreen(convert(frame(for: row), to: nil))
    }
    /// The row's frame on screen, nil when it is not laid out.
    /// A pinned workspace uses its drawn pill rather than its wider layout cell.
    func hoverCardAnchor(for id: WorkspaceID) -> CGRect? {
        guard let window else { return nil }
        if let row = displayed.row(for: .workspace(id)) { return window.convertToScreen(convert(frame(for: row), to: nil)) }
        guard let pinned = blockItemView(for: id) else { return nil }
        return window.convertToScreen(pinned.convert(pinned.pill.frame, to: nil))
    }
    /// A workspace preview touches the row's fill, before the sidebar's resize/drag thumb.
    /// Pinned items use their drawn pill rather than their wider layout cell.
    func hoverCardBand(for id: WorkspaceID) -> CGRect? {
        hoverCardAnchor(for: id)
    }
    /// A group header's band across the sidebar column, as `hoverCardBand(for:)`.
    func hoverCardBand(forGroup id: GroupID) -> CGRect? {
        hoverCardAnchor(forGroup: id).flatMap(hoverCardBand(row:))
    }
    private func hoverCardBand(row: CGRect) -> CGRect? {
        sidebarColumnOnScreen.map { HoverCardEscapeGeometry.rowBand(row: row, column: $0) }
    }
}

extension SidebarViewComponents {
    /// CPU and memory for the workspace hover card. Sampled only while a
    /// card is pending or shown.
    public var resourceSource: (any ResourceSampleSource)? {
        get { list.hoverCard.resources.source }
        set { list.hoverCard.resources.setSource(newValue) }
    }

    /// Shows workspace `id`'s hover card (CPU and memory) now, until the
    /// next key press, click or scroll. False when its row is not shown.
    @discardableResult
    public func showHoverCard(for id: WorkspaceID) -> Bool {
        list.showHoverCard(for: id)
    }

    /// The app's one hover card coordinator (the App injects it).
    public var hoverCards: HoverCardCoordinator {
        get { list.hoverCards }
        set { list.hoverCards = newValue }
    }

    /// The user's customization: its hover card replaces the built-in one (cx-swovq.1).
    public var customization: (any SidebarCustomization)? {
        get { list.hoverCard.customization }
        set { list.hoverCard.customization = newValue }
    }

    /// A workspace's history for its hover card (u3320): prompts, starts, waits and finished
    /// turns, newest first. Nil shows no history.
    public var timelineSource: SidebarTimelineSource? {
        get { list.hoverCard.timelineSource }
        set { list.hoverCard.timelineSource = newValue }
    }

    /// True while the workspace hover card samples resources.
    public var isSamplingResources: Bool { list.hoverCard.resources.isOpen }

    /// Workspace `id`'s row on screen, scrolled into view first; nil when the
    /// row is not shown (the icon picker anchors its popover here).
    public func rowFrameOnScreen(for id: WorkspaceID) -> CGRect? {
        guard let row = list.displayed.row(for: .workspace(id)) else { return nil }
        list.scrollToVisible(list.frame(for: row))
        return list.hoverCardAnchor(for: id)
    }

    /// Group `id`'s row on screen (its header, or the one row it draws as), scrolled into view first; nil when
    /// neither is shown (the icon picker anchors its popover here).
    public func groupRowFrameOnScreen(for id: GroupID) -> CGRect? {
        guard let row = list.displayed.groupRow(id), let window = list.window else { return nil }
        list.scrollToVisible(list.frame(for: row))
        return window.convertToScreen(list.convert(list.frame(for: row), to: nil))
    }

    /// The name of the shown group called `name` on screen, scrolled into view first (a capture tour double-clicks it
    /// to rename the group in place); nil when no shown group has that name.
    public func groupNameFrameOnScreen(named name: String) -> CGRect? {
        guard let id = list.groups.values.first(where: { $0.name == name })?.id, groupRowFrameOnScreen(for: id) != nil,
              let window = list.window else { return nil }
        list.realizeVisibleRows()
        guard let header = list.rowViews[.group(id)] as? GroupHeaderRowView else { return nil }
        header.layoutSubtreeIfNeeded()
        return window.convertToScreen(header.convert(header.name.frame, to: nil))
    }
}
