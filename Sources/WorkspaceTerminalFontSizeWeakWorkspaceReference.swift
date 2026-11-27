extension WorkspaceTerminalFontSizeCoordinator {
    final class WeakWorkspaceReference {
        weak var value: Workspace?

        init(_ value: Workspace) {
            self.value = value
        }
    }
}
