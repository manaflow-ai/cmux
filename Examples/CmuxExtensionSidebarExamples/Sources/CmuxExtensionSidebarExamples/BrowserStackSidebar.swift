import CmuxExtensionKit

public struct BrowserStackSidebar: CmuxExtensionSidebarProvider {
    public let descriptor = CmuxExtensionSidebarProviderDescriptor(
        id: "com.example.cmux.sidebar.browser-stack",
        title: localized("example.sidebar.browserStack.title", "Browser Stack"),
        subtitle: localized("example.sidebar.browserStack.subtitle", "User extension"),
        systemImageName: "square.on.square",
        mode: nil,
        isHostProvided: false
    )

    public init() {}

    public func render(snapshot: CmuxExtensionSidebarSnapshot) -> CmuxExtensionSidebarRenderModel {
        let section = ExampleSidebarSection(
            id: "browser-stack",
            title: localized("example.sidebar.group.browserStack", "Browser Stack"),
            systemImageName: "square.on.square",
            projectRootPath: nil,
            workspaces: snapshot.workspaces
        )
        .render(
            accessory: nil,
            trailingText: recentActivityText,
            leadingIcon: browserIcon
        )

        return renderModel(
            providerId: descriptor.id,
            snapshot: snapshot,
            sections: [section],
            presentation: .browserStack
        )
    }

    private func recentActivityText(_ workspace: CmuxExtensionWorkspaceSnapshot) -> CmuxExtensionSidebarRenderText? {
        workspace.latestSubmittedAt.map { .relativeDate($0, style: .compact) }
    }

    private func browserIcon(_ workspace: CmuxExtensionWorkspaceSnapshot) -> CmuxExtensionSidebarRenderIcon? {
        let title = workspace.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if title.contains("google") {
            return CmuxExtensionSidebarRenderIcon(
                text: "G",
                foregroundColorHex: "#4285F4",
                backgroundColorHex: "#FFFFFF"
            )
        }
        if title.contains("hacker") || title.contains("ycombinator") || title.contains("yc") {
            return CmuxExtensionSidebarRenderIcon(
                text: "Y",
                foregroundColorHex: "#FFFFFF",
                backgroundColorHex: "#FF6600",
                shape: .roundedRectangle
            )
        }
        if title == "x" || title.hasPrefix("x.") || title.contains("twitter") || title.contains("what's happening") {
            return CmuxExtensionSidebarRenderIcon(
                text: "X",
                foregroundColorHex: "#FFFFFF",
                backgroundColorHex: "#000000",
                shape: .roundedRectangle
            )
        }
        if title.contains("dia") || workspace.unreadCount > 0 {
            return CmuxExtensionSidebarRenderIcon(
                systemImageName: "bubble.left.fill",
                foregroundColorHex: "#D8D8D8",
                backgroundColorHex: "#000000"
            )
        }
        return CmuxExtensionSidebarRenderIcon(
            systemImageName: "bubble.left.fill",
            foregroundColorHex: "#D0D0D0",
            backgroundColorHex: "#5A5A5A"
        )
    }
}
