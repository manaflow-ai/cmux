import SwiftUI

extension TabItemView {
    func contextMenuLabel(multi: String, single: String, isMulti: Bool) -> String {
        isMulti ? multi : single
    }

    func remoteContextMenuWorkspaces() -> [Workspace] {
        guard !remoteContextMenuWorkspaceIds.isEmpty else { return [] }
        return remoteContextMenuWorkspaceIds.compactMap { workspaceId in
            tabManager.tabs.first(where: { $0.id == workspaceId })
        }
    }

    @ViewBuilder
    func workspaceNotificationMuteContextMenuItems(targetIds: [UUID], isMulti: Bool) -> some View {
        Menu(workspaceNotificationMuteLabel(isMulti: isMulti)) {
            ForEach(notificationMuteMenuOptions) { option in
                Button(option.title) {
                    notificationStore.muteNotifications(
                        forTabIds: targetIds,
                        until: option.expiration()
                    )
                }
            }
        }
        .disabled(targetIds.isEmpty)

        if contextMenuWorkspaceMuteActive {
            Button(workspaceNotificationUnmuteLabel(isMulti: isMulti)) {
                notificationStore.unmuteNotifications(forTabIds: targetIds)
            }
            .disabled(targetIds.isEmpty)
        }
    }

    private func workspaceNotificationMuteLabel(isMulti: Bool) -> String {
        isMulti
            ? String(localized: "contextMenu.muteWorkspacesNotifications", defaultValue: "Mute Workspaces Notifications")
            : String(localized: "contextMenu.muteWorkspaceNotifications", defaultValue: "Mute Workspace Notifications")
    }

    private func workspaceNotificationUnmuteLabel(isMulti: Bool) -> String {
        isMulti
            ? String(localized: "contextMenu.unmuteWorkspacesNotifications", defaultValue: "Unmute Workspaces Notifications")
            : String(localized: "contextMenu.unmuteWorkspaceNotifications", defaultValue: "Unmute Workspace Notifications")
    }
}
