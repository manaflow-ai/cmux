/// Workspace-management actions shared by title menus and Labs switchers.
struct WorkspaceTitleMenuActions {
    let presentCustomization: () -> Void
    let presentRename: () -> Void
    let toggleReadState: () -> Void
    let requestClose: () -> Void
}
