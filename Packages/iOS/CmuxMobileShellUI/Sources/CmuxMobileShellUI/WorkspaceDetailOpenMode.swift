/// Whether a workspace detail route may attach its remote terminal workspace.
enum WorkspaceDetailOpenMode: Hashable {
    case remoteWorkspace
    case localBrowser

    var opensRemoteWorkspace: Bool {
        self == .remoteWorkspace
    }
}
