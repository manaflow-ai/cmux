/// Immutable workspace-management state rendered by title and switcher menus.
struct WorkspaceTitleMenuContentValue: Equatable {
    let workspaceName: String
    let hasUnread: Bool
    let canCustomizeWorkspace: Bool
    let canRenameWorkspace: Bool
    let canToggleReadState: Bool
    let canCloseWorkspace: Bool
    let showsRenameAlongsideCustomization: Bool
}
