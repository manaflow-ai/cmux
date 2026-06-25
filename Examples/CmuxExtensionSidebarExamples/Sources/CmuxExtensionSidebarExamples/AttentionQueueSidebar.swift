import CmuxSidebarProviderKit

public struct AttentionQueueSidebar: CmuxSidebarProvider {
    public let descriptor = CmuxSidebarProviderDescriptor(
        id: "com.example.cmux.sidebar.attention-queue",
        title: localized("example.sidebar.attentionQueue.title", "Attention Queue"),
        subtitle: localized("example.sidebar.attentionQueue.subtitle", "User extension"),
        systemImageName: "bell",
        isHostProvided: false
    )

    public init() {}

    public func render(snapshot: CmuxSidebarProviderSnapshot) -> CmuxSidebarProviderRenderModel {
        let selected = snapshot.selectedWorkspaceId
        let active = snapshot.workspaces.filter { $0.id == selected }
        let pinned = snapshot.workspaces.filter { $0.isPinned && $0.id != selected }
        let attention = snapshot.workspaces.filter { workspace in
            workspace.id != selected && !workspace.isPinned && needsAttention(workspace)
        }
        let quiet = snapshot.workspaces.filter { workspace in
            workspace.id != selected && !workspace.isPinned && !needsAttention(workspace)
        }

        let sections = [
            ExampleSidebarSection(
                id: "active",
                title: localized("example.sidebar.group.active", "Active"),
                systemImageName: "circle.fill",
                projectRootPath: nil,
                workspaces: active
            )
            .render(subtitle: rowSubtitle, subtitleRole: rowSubtitleRole),
            ExampleSidebarSection(
                id: "pinned",
                title: localized("example.sidebar.group.pinned", "Pinned"),
                systemImageName: "pin",
                projectRootPath: nil,
                workspaces: pinned
            )
            .render(subtitle: rowSubtitle, subtitleRole: rowSubtitleRole),
            ExampleSidebarSection(
                id: "attention",
                title: localized("example.sidebar.group.needsAttention", "Needs Attention"),
                systemImageName: "bell",
                projectRootPath: nil,
                workspaces: attention
            )
            .render(subtitle: rowSubtitle, subtitleRole: rowSubtitleRole),
            ExampleSidebarSection(
                id: "quiet",
                title: localized("example.sidebar.group.quiet", "Quiet"),
                systemImageName: "checkmark.circle",
                projectRootPath: nil,
                workspaces: quiet
            )
            .render(subtitle: rowSubtitle, subtitleRole: rowSubtitleRole),
        ]

        return renderModel(providerId: descriptor.id, snapshot: snapshot, sections: sections)
    }

    private func needsAttention(_ workspace: CmuxSidebarProviderWorkspace) -> Bool {
        workspace.unreadCount > 0
            || trimmed(workspace.latestNotificationText) != nil
            || (hasRemoteTarget(workspace) && (
                workspace.remoteConnectionState == "connecting"
                    || workspace.remoteConnectionState == "reconnecting"
                    || workspace.remoteConnectionState == "disconnected"
            ))
    }

    private func rowSubtitle(_ workspace: CmuxSidebarProviderWorkspace) -> CmuxSidebarProviderText? {
        if let notification = trimmed(workspace.latestNotificationText) {
            return .plain(notification)
        }
        if hasRemoteTarget(workspace),
           let remoteState = trimmed(workspace.remoteConnectionState),
           remoteState != "connected" {
            return .plain(remoteState)
        }
        return trimmed(workspace.customDescription).map(CmuxSidebarProviderText.plain)
    }

    private func rowSubtitleRole(_ workspace: CmuxSidebarProviderWorkspace) -> CmuxSidebarProviderRowSubtitleRole? {
        guard let notification = trimmed(workspace.latestNotificationText),
              Self.isAgentStatusNotification(notification) else {
            return nil
        }
        return .agentStatus
    }

    private static func isAgentStatusNotification(_ text: String) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "waiting for input"
            || normalized == "needs input"
            || normalized.hasSuffix(" needs input")
            || normalized.hasSuffix(" needs your input")
            || normalized.hasSuffix(" is waiting for your input")
    }

    private func hasRemoteTarget(_ workspace: CmuxSidebarProviderWorkspace) -> Bool {
        trimmed(workspace.remoteDisplayTarget) != nil
    }
}
