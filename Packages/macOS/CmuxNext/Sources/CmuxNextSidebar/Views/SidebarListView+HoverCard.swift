public import AppKit
public import CmuxNextDesign
public import CmuxNextResources
public import CmuxNextWakeups
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
        guard let window, workspaces[id] != nil, let row = displayed.row(for: .workspace(id)) else { return false }
        scrollToVisible(frame(for: row))
        let target = HoverTarget(id: WorkspaceHoverCardController.targetID(id), window: window.windowNumber, delay: hoverCard.delay)
        hoverCards.pin(target, from: hoverCard)
        return hoverCards.isShowing(target.id)
    }
    /// The workspace row `point` (this view's coordinates) hovers, by the
    /// list's own hover rule, that may have a card now: none during a drag or rename, or off the visible rows.
    func hoverCardWorkspace(at point: CGPoint) -> WorkspaceID? {
        // visibility-walk-allow: hover hit test: a hidden list hovers no row
        guard drag == nil, !inlineRename.isActive, visibleRect.contains(point), !isHiddenOrHasHiddenAncestor,
              // The list's own rows (a dictionary): `model.isPlaceholder` walks every section, and this
              // runs on each scroll frame (hover geometry), O(workspaces) per frame at 1,000 rows.
              case .workspace(let id)? = hoverHit(at: point)?.key, let row = workspaces[id],
              !row.rowState.isPending else { return nil }
        return id
    }
    /// The group header under `point` that may have a summary card now
    /// (`sidebar.hoverCards.groups.workspaceGroups`): none during a drag, a rename or an open group
    /// editor. One row lookup by position, like a workspace row's: a hover never walks the groups.
    func hoverCardGroup(at point: CGPoint) -> GroupID? {
        guard DesignSettings.shared.groupHoverCard.workspaceGroups, drag == nil, !inlineRename.isActive,
              // visibility-walk-allow: hover hit test: a hidden list hovers no group header
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
    /// The group header's frame on screen, nil when it is not laid out.
    func hoverCardAnchor(forGroup id: GroupID) -> CGRect? {
        guard let window, let row = displayed.row(for: .group(id)) else { return nil }
        return window.convertToScreen(convert(frame(for: row), to: nil))
    }
    /// The row's frame on screen, nil when it is not laid out.
    func hoverCardAnchor(for id: WorkspaceID) -> CGRect? {
        guard let window, let row = displayed.row(for: .workspace(id)) else { return nil }
        return window.convertToScreen(convert(frame(for: row), to: nil))
    }
    /// Where a workspace row's hover card goes: the row's band across the sidebar column
    /// (`HoverCardEscapeGeometry.rowBand`), so the card's top is the row's top and its near edge
    /// one device pixel off the sidebar's visible edge. Nil when the row is not laid out.
    func hoverCardBand(for id: WorkspaceID) -> CGRect? {
        hoverCardAnchor(for: id).flatMap(hoverCardBand(row:))
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
    public var resourceSource: (any ResourceSampleSource)? { list.hoverCard.resources.source }

    /// Samples the hover card's workspace from `source`, each next sample on `deadlines`, the app's one deadline
    /// scheduler (`AppServices.mainDeadlines`).
    public func setResourceSource(_ source: (any ResourceSampleSource)?, deadlines: MainDeadlineScheduler) {
        list.hoverCard.resources.setSource(source, deadlines: deadlines)
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

    /// Group `id`'s header row on screen, scrolled into view first; nil when
    /// the header is not shown (the icon picker anchors its popover here).
    public func groupRowFrameOnScreen(for id: GroupID) -> CGRect? {
        guard let row = list.displayed.row(for: .group(id)), let window = list.window else { return nil }
        list.scrollToVisible(list.frame(for: row))
        return window.convertToScreen(list.convert(list.frame(for: row), to: nil))
    }
}
