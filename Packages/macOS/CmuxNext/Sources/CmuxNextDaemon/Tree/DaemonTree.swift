import Foundation

// DaemonTree, WorkspaceSnapshot, PaneSnapshot and WorkspaceGroupSnapshot are generated from
// cmux-tui/spec/sdk-schema.json (swift_app/bindings.json, family Tree).

extension DaemonTree {
    /// Sets each saved record's `openGroup` from the live group whose
    /// `savedID` names it.
    public mutating func linkSavedTabGroups() {
        var open: [SavedTabGroupID: TabGroupID] = [:]
        for workspace in workspaces {
            for screen in workspace.screens {
                for pane in screen.panes {
                    for group in pane.tabGroups { if let saved = group.savedID { open[saved] = group.id } }
                }
            }
        }
        savedTabGroups = savedTabGroups.map { saved in
            var saved = saved
            saved.openGroup = open[saved.id]
            return saved
        }
    }
}
