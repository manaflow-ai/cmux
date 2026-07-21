import Foundation
public import CmuxMobileShellModel

extension MobileWorkspacePreview {
    /// Build a preview value from a remote workspace-list entry.
    /// - Parameter remote: A workspace decoded from the RPC response.
    public init(remote: MobileSyncWorkspaceListResponse.Workspace) {
        self.init(
            id: ID(rawValue: remote.id),
            windowID: remote.windowID,
            name: remote.title,
            currentDirectory: remote.currentDirectory,
            isPinned: remote.isPinned ?? false,
            groupID: remote.groupID.map { MobileWorkspaceGroupPreview.ID(rawValue: $0) },
            previewText: remote.preview,
            previewAt: remote.previewAt.map { Date(timeIntervalSince1970: $0) },
            lastActivityAt: remote.lastActivityAt.map { Date(timeIntervalSince1970: $0) },
            hasUnread: remote.hasUnread ?? false,
            terminals: remote.terminals.map { terminal in
                MobileTerminalPreview(remote: terminal)
            },
            layout: remote.layout.map(MobilePaneLayout.init(remote:))
        )
    }
}

private extension MobilePaneLayout {
    init(remote: MobileSyncWorkspaceListResponse.Layout) {
        self.init(
            version: remote.version,
            focusedPaneID: remote.focusedPaneID,
            root: Node(remote: remote.root)
        )
    }
}

private extension MobilePaneLayout.Node {
    init(remote: MobileSyncWorkspaceListResponse.Layout.Node) {
        switch remote {
        case let .split(split):
            self = .split(MobilePaneSplit(remote: split))
        case let .pane(pane):
            self = .pane(MobilePaneNode(remote: pane))
        }
    }
}

private extension MobilePaneSplit {
    init(remote: MobileSyncWorkspaceListResponse.Layout.Split) {
        self.init(
            id: remote.id,
            orientation: MobilePaneSplitOrientation(remote: remote.orientation),
            ratio: min(max(remote.ratio, 0.05), 0.95),
            first: MobilePaneLayout.Node(remote: remote.first),
            second: MobilePaneLayout.Node(remote: remote.second)
        )
    }
}

private extension MobilePaneSplitOrientation {
    init(remote: MobileSyncWorkspaceListResponse.Layout.Split.Orientation) {
        switch remote {
        case .horizontal:
            self = .horizontal
        case .vertical:
            self = .vertical
        }
    }
}

private extension MobilePaneNode {
    init(remote: MobileSyncWorkspaceListResponse.Layout.Pane) {
        self.init(
            id: remote.id,
            selectedSurfaceID: remote.selectedSurfaceID,
            surfaces: remote.surfaces.map(MobilePaneSurface.init(remote:))
        )
    }
}

private extension MobilePaneSurface {
    init(remote: MobileSyncWorkspaceListResponse.Layout.Surface) {
        self.init(
            id: remote.id,
            type: MobilePaneSurfaceType(remoteRawValue: remote.type),
            title: remote.title
        )
    }
}

private extension MobilePaneSurfaceType {
    init(remoteRawValue: String) {
        switch remoteRawValue {
        case "terminal": self = .terminal
        case "browser": self = .browser
        case "markdown": self = .markdown
        case "filepreview": self = .filepreview
        case "rightSidebarTool": self = .rightSidebarTool
        case "customSidebar": self = .customSidebar
        case "agentSession": self = .agentSession
        case "project": self = .project
        case "extensionBrowser": self = .extensionBrowser
        case "workspaceTodo": self = .workspaceTodo
        case "cloudVMLoading": self = .cloudVMLoading
        default: self = .other(remoteRawValue)
        }
    }
}

extension MobileWorkspaceGroupPreview {
    /// Build a group preview value from a remote workspace-list group entry.
    /// - Parameter remote: A group decoded from the RPC response.
    public init(remote: MobileSyncWorkspaceListResponse.Group) {
        self.init(
            id: ID(rawValue: remote.id),
            name: remote.name,
            isCollapsed: remote.isCollapsed,
            isPinned: remote.isPinned,
            anchorWorkspaceID: MobileWorkspacePreview.ID(rawValue: remote.anchorWorkspaceID)
        )
    }
}

extension MobileTerminalPreview {
    /// Build a preview value from a remote terminal entry.
    /// - Parameter remote: A terminal decoded from the RPC response.
    public init(remote: MobileSyncWorkspaceListResponse.Terminal) {
        self.init(
            id: ID(rawValue: remote.id),
            name: remote.title,
            currentDirectory: remote.currentDirectory,
            isReady: remote.isReady ?? true,
            isFocused: remote.isFocused
        )
    }
}
