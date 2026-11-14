extension WorkspaceModel {
    /// Public ids (`term_…`) of this workspace's terminals, in tab order. Remote-terminal tabs live on another
    /// session and are not included. Reads this workspace's screens, panes and tabs only, so an observer of it
    /// wakes for this workspace alone (the clipboard-read subscription, one observation per workspace).
    public var terminalResourceIDs: [String] {
        var ids: [String] = []
        for screen in screens {
            for pane in screen.panes {
                for tab in pane.tabs where tab.kind == .pty {
                    if let id = tab.terminalResourceID?.rawValue { ids.append(id) }
                }
            }
        }
        return ids
    }
}
