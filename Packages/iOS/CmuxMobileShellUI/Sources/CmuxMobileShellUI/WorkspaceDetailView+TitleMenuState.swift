extension WorkspaceDetailView {
    var hasTitleMenuActions: Bool {
        workspace.actionCapabilities.supportsWorkspaceActions
            || workspace.actionCapabilities.supportsReadStateActions
            || closeWorkspace != nil
    }
}
