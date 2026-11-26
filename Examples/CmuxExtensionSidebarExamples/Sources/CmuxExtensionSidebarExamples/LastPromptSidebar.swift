import CmuxSidebarProviderKit

public struct LastPromptSidebar: CmuxSidebarProvider {
    public let descriptor = CmuxSidebarProviderDescriptor(
        id: "com.example.cmux.sidebar.last-prompt",
        title: localized("example.sidebar.lastPrompt.title", "Last Prompt"),
        subtitle: localized("example.sidebar.lastPrompt.subtitle", "User extension"),
        systemImageName: "clock",
        isHostProvided: false
    )

    public init() {}

    public func render(snapshot: CmuxSidebarProviderSnapshot) -> CmuxSidebarProviderRenderModel {
        let recent = snapshot.workspaces
            .filter { $0.latestSubmittedAt != nil }
            .sorted { lhs, rhs in
                guard let lhsDate = lhs.latestSubmittedAt else { return false }
                guard let rhsDate = rhs.latestSubmittedAt else { return true }
                return lhsDate > rhsDate
            }

        let sections = [
            ExampleSidebarSection(
                id: "recent",
                title: localized("example.sidebar.group.recentPrompts", "Recent Prompts"),
                systemImageName: "clock",
                projectRootPath: nil,
                workspaces: recent
            )
            .render(subtitle: promptSubtitle, trailingText: promptTrailingText),
            ExampleSidebarSection(
                id: "none",
                title: localized("example.sidebar.group.noPrompts", "No Prompts"),
                systemImageName: "tray",
                projectRootPath: nil,
                workspaces: snapshot.workspaces.filter { $0.latestSubmittedAt == nil }
            )
            .render(subtitle: promptSubtitle, trailingText: promptTrailingText),
        ]

        return renderModel(providerId: descriptor.id, snapshot: snapshot, sections: sections)
    }

    private func promptSubtitle(_ workspace: CmuxSidebarProviderWorkspace) -> CmuxSidebarProviderText? {
        if let message = trimmed(workspace.latestSubmittedMessage) {
            return .plain(message)
        }
        return .localized(localized("example.sidebar.noPromptsYet", "No prompts yet"))
    }

    private func promptTrailingText(_ workspace: CmuxSidebarProviderWorkspace) -> CmuxSidebarProviderText? {
        workspace.latestSubmittedAt.map { .relativeDate($0, style: .compact) }
    }
}
