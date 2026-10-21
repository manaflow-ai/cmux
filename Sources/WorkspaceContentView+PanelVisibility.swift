import Foundation

extension WorkspaceContentView {
    static func panelVisibleInUI(
        isWorkspaceVisible: Bool,
        paneHasSelectedTab: Bool,
        isSelectedInPane: Bool,
        isFocused: Bool,
        isFallbackInPane: Bool = false
    ) -> Bool {
        // During pane/tab reparenting, Bonsplit can transiently report no selected
        // tab. Keep the focused panel or Bonsplit's first-tab fallback visible for
        // that gap; if another tab is selected, stale content must stay hidden.
        return WorkspacePanelVisibilityPolicy.panelVisibleInUI(
            isWorkspaceVisible: isWorkspaceVisible,
            paneHasSelectedTab: paneHasSelectedTab,
            isSelectedInPane: isSelectedInPane,
            isFocused: isFocused,
            isFallbackInPane: isFallbackInPane
        )
    }

}
