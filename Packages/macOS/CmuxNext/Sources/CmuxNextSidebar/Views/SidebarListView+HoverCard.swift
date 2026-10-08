public import AppKit
public import CmuxNextDesign
// The list's targets for the app's hover cards (WorkspaceHoverCardController,
// HoverCardCoordinator): workspace rows, hit-tested by position.
extension SidebarListView {
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
    /// The workspace row under `point` (this view's coordinates) that may
    /// have a card now: none during a drag or rename, or off the visible rows.
    func hoverCardWorkspace(at point: CGPoint) -> WorkspaceID? {
        guard drag == nil, !inlineRename.isActive, visibleRect.contains(point), !isHiddenOrHasHiddenAncestor,
              case .workspace(let id)? = displayed.row(at: point.y)?.key, workspaces[id] != nil else { return nil }
        return id
    }
    /// The row's frame on screen, nil when it is not laid out.
    func hoverCardAnchor(for id: WorkspaceID) -> CGRect? {
        guard let window, let row = displayed.row(for: .workspace(id)) else { return nil }
        return window.convertToScreen(convert(frame(for: row), to: nil))
    }
}

extension SidebarView {
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
