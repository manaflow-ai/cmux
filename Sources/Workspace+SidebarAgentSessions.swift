import Foundation

extension Workspace {
    /// The live coding-agent sessions hosted by this workspace's panes, in the
    /// given tab order, for the sidebar's session rows. A record is a member
    /// when its pane (the registry's `surfaceID`) is one of these panels; the
    /// record's stored workspace id is ignored because it goes stale across
    /// relaunches while pane ids stay stable.
    func sidebarAgentSessionSnapshots(orderedPanelIds: [UUID]) -> [SidebarAgentSessionSnapshot] {
        guard !orderedPanelIds.isEmpty,
              let service = TerminalController.shared.agentChatTranscriptService else { return [] }
        return SidebarAgentSessionSnapshotBuilder().sessions(
            orderedPanelIds: orderedPanelIds,
            liveRecord: { panelId in service.liveSessionRecord(surfaceID: panelId.uuidString) },
            paneTitle: { panelId in self.panelTitle(panelId: panelId) }
        )
    }
}
