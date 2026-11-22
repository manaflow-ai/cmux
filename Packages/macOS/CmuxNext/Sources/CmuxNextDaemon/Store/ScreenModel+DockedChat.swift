extension ScreenModel {
    /// The panes beside the agent chat dock column that holds `pane` (Home's Chief dock, a docked agent chat), in
    /// layout order: every pane of this screen outside its dock columns. Nil when `pane` is in no agent chat dock
    /// column of this screen.
    ///
    /// Cmd-L in a docked chat, which has no address bar, focuses the address bar of a browser among them.
    ///
    /// - Parameter pane: The pane the keyboard is in.
    /// - Returns: The panes beside the dock, or nil when `pane` is not in an agent chat dock column here.
    public func panesBeside(dockedChat pane: PaneID) -> [PaneModel]? {
        guard columns.contains(where: { $0.dock?.role == .agentChat && $0.layout.paneIDs.contains(pane) }) else { return nil }
        let docked = Set(columns.filter { $0.dock != nil }.flatMap(\.layout.paneIDs))
        return panes.filter { !docked.contains($0.handle) }
    }
}
