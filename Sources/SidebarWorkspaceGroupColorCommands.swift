import AppKit
import Foundation

/// Group Color menu commands for one workspace group, shared by the SwiftUI and
/// AppKit group headers through ``SidebarGroupHeaderRowActions``. The stable
/// group id is captured; the current color is read when a command runs.
@MainActor
struct SidebarWorkspaceGroupColorCommands {
    weak var tabManager: TabManager?
    let groupId: UUID

    /// Sets the group color; nil clears it.
    func setColor(_ hex: String?) {
        tabManager?.setWorkspaceGroupColor(groupId: groupId, hex: hex)
    }

    func chooseCustomColor() {
        guard let tabManager else { return }
        let currentHex = tabManager.workspaceGroups.first(where: { $0.id == groupId })?.customColor
        guard let hex = WorkspaceCustomColorPrompt.run(
            title: String(localized: "alert.customGroupColor.title", defaultValue: "Custom Group Color"),
            currentHex: currentHex,
            presentingWindow: tabManager.workspaceGroupAnchor(for: groupId).flatMap {
                AppDelegate.shared?.mainWindowContainingWorkspace($0.id)
            }
        ) else { return }
        tabManager.setWorkspaceGroupColor(groupId: groupId, hex: hex)
    }
}
