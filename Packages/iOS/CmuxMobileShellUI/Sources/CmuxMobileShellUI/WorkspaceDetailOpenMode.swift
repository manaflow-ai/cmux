/// Whether a workspace detail route may attach its remote terminal workspace.
enum WorkspaceDetailOpenMode: Hashable {
    case remoteWorkspace
    case localBrowser

    var opensRemoteWorkspace: Bool {
        self == .remoteWorkspace
    }

    var mountsRemoteWorkspaceSurface: Bool {
        self == .remoteWorkspace
    }

    var showsRemoteWorkspaceControls: Bool {
        self == .remoteWorkspace
    }

    var returnsToSurfaceGridOnBrowserClose: Bool {
        self == .localBrowser
    }

    func performRemoteAction(_ action: () -> Void) {
        guard self == .remoteWorkspace else { return }
        action()
    }
}
