import AppKit
import CmuxNextDesign

extension WorkspaceRowView {
    /// The row's callbacks for workspace `id` in `list`, set on every dequeue
    /// (`SidebarListView.wire`) so a recycled view never keeps a previous
    /// row's target.
    func wire(_ id: WorkspaceID, in list: SidebarListView) {
        onClose = { [weak list] in list?.model.send(.close([id])) }
        onMore = list.contextMenuProvider == nil ? nil : { [weak list] in list.map { SidebarRowMenu(list: $0).show(for: id) } }
        onSelect = { [weak list] in list?.model.click(id) }
        // Redraw now: left to the tree's observation, the fold would wait
        // out the calm-movement hold until the pointer leaves the sidebar.
        // The row's own chevron says which way it goes: a parent below the top level starts folded.
        // A row whose chats have subagents is a parent too (its subagent lines fold), though no session lists under it.
        onToggleTree = { [weak list, weak self] in
            let parents = Set(list?.model.allWorkspaces.filter { $0.subagents?.items.isEmpty == false }.map(\.id) ?? [])
            SidebarSessionTree.shared.toggle(id, folded: self?.treeFold == .collapsed, keeping: parents)
            list?.reload(animated: true)
        }
        // A subagent's line opens its pane beside its chat; the stacked line and "N more" show the chat.
        subagentsView.onOpen = { [weak list, weak self] subagent in
            guard let tab = subagent?.tab ?? self?.subagentsView.strip?.tab else { return }
            list?.model.openSubagent?(id, tab, subagent)
        }
        onToggleAudio = { [weak list] in list?.model.send(.toggleWorkspaceAudio(id)) }
        // The drive indicator's menu: Go to shows the agent's tab, Stop ends what it drives; each row a registered action.
        driveIndicator.makeItem = { [weak list] command, title in list?.driveMenuItem?(id, command, title) }
        // An expanded row's hover pin (cx-13w3): nil while the App offers none.
        isPinned = { [weak list] in list?.model.workspacePin?.isPinned(id) }
        onPin = { [weak list] in list?.model.workspacePin?.toggle(id) }
    }

    /// Reads the agent mark, presence dot, row badge and stack size settings;
    /// one shared observation (`SidebarTunablesWatch`) redraws the live rows
    /// when one changes, not one new registration per configure.
    func observedTunables() -> SidebarTunablesWatch.Values {
        SidebarTunablesWatch.shared.values(for: self)
    }
}
