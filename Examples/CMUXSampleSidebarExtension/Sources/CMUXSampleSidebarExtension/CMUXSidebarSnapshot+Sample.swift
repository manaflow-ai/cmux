import CmuxExtensionKit
import Foundation

public extension CMUXSidebarSnapshot {
    static let sample = CMUXSidebarSnapshot(
        sequence: 1,
        windowID: UUID(uuidString: "00000000-0000-0000-0000-000000000001"),
        selectedWorkspaceID: UUID(uuidString: "00000000-0000-0000-0000-000000000101"),
        workspaces: [
            CMUXSidebarWorkspace(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000101")!,
                title: "ExtensionKit Host",
                detail: "feature-sidebar-extension-kit",
                isPinned: true,
                rootPath: "/Users/example/cmux",
                projectRootPath: "/Users/example/cmux",
                gitBranch: "feature/sidebar-extension-kit",
                unreadCount: 2,
                latestNotification: "Tests passed",
                listeningPorts: [17320, 9300],
                pullRequestURLs: ["https://github.com/manaflow-ai/cmux/pull/4994"]
            ),
            CMUXSidebarWorkspace(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000102")!,
                title: "Sample Consumer",
                detail: "Extension workspace data",
                isPinned: false,
                rootPath: "/Users/example/sample",
                projectRootPath: "/Users/example/sample",
                gitBranch: "main",
                unreadCount: 0,
                latestNotification: nil,
                listeningPorts: [],
                pullRequestURLs: []
            ),
        ]
    )
}
