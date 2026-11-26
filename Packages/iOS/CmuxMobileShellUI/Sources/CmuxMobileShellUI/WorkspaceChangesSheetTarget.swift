struct WorkspaceChangesSheetTarget: Identifiable {
    var id: String { workspaceID }

    let workspaceID: String
    let workspaceTitle: String
}
