import SwiftUI

/// "Merge Workspace into" submenu, shared by the sidebar row menu and the
/// Workspace menu. Picking a workspace moves every tab into its focused pane.
/// Both menus build their content when presented, so the targets read here
/// are the live window topology.
struct WorkspaceMergeIntoMenu: View {
    let sourceWorkspaceId: UUID

    var body: some View {
        let targets = AppDelegate.shared?.workspaceMergeTargets(for: sourceWorkspaceId) ?? []
        Menu(String(localized: "contextMenu.mergeWorkspaceInto", defaultValue: "Merge Workspace into")) {
            ForEach(targets) { target in
                Button(target.label) {
                    _ = AppDelegate.shared?.mergeWorkspaceIntoFocusedPane(sourceWorkspaceId, into: target.workspaceId)
                }
                .disabled(!target.isEnabled)
            }
        }
        .disabled(!targets.contains(where: \.isEnabled))
    }
}
