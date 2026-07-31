extension WorkspaceDetailView {
    var hasTitleMenuActions: Bool {
        customizeWorkspace != nil
            || workspace.actionCapabilities.supportsWorkspaceActions
            || workspace.actionCapabilities.supportsReadStateActions
            || closeWorkspace != nil
    }
}
