import AppKit
import CmuxNextDesign
import Observation

extension WorkspaceRowView {
    /// The row's callbacks for workspace `id` in `list`, set on every dequeue
    /// (`SidebarListView.wire`) so a recycled view never keeps a previous
    /// row's target.
    func wire(_ id: WorkspaceID, in list: SidebarListView) {
        onClose = { [weak list] in list?.model.send(.close([id])) }
        onMore = list.contextMenuProvider == nil ? nil : { [weak list] in list.map { SidebarRowMenu(list: $0).show(for: id) } }
        onSelect = { [weak list] in list?.model.click(id) }
        onToggleTabs = { [weak list] in list?.model.toggleWorkspaceTabs(id); list?.reload(animated: true) }
        // An expanded row's hover pin (cx-13w3): nil while the App offers none.
        isPinned = { [weak list] in list?.model.workspacePin?.isPinned(id) }
        onPin = { [weak list] in list?.model.workspacePin?.toggle(id) }
    }

    /// Reads the agent mark, presence dot, row badge and stack size settings and redraws the row once when one changes (no polling).
    func observedTunables() -> (agentMark: SidebarAgentMarkVariant, presenceDots: Bool, rowBadge: SidebarRowBadgeStyle, stackCap: SidebarRowBadgeStackCap) {
        withObservationTracking {
            (SidebarTunables.agentMark.value, SidebarTunables.presenceDots.value, SidebarRowBadgeStyle.tunable.value, SidebarRowBadgeStackCap.tunable.value)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, let last = self.lastConfiguration else { return }
                self.configure(last.0, row: last.1, badgeStyle: last.2)
            }
        }
    }
}
