import Foundation

extension WorkspaceContentView {
    static func panelVisibleInUI(
        isWorkspaceVisible: Bool,
        paneHasSelectedTab: Bool,
        isSelectedInPane: Bool,
        isFocused: Bool
    ) -> Bool {
        // During pane/tab reparenting, Bonsplit can transiently report selected=false
        // for the currently focused panel. Keep focused content visible only when
        // the pane has no selected tab to report; if another tab is selected, a
        // stale focused terminal must not keep its portal view visible.
        return WorkspacePanelVisibilityPolicy.panelVisibleInUI(
            isWorkspaceVisible: isWorkspaceVisible,
            paneHasSelectedTab: paneHasSelectedTab,
            isSelectedInPane: isSelectedInPane,
            isFocused: isFocused
        )
    }

}
