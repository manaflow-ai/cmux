import CmuxNextActions

/// Files pane actions (u2360): `files.open` opens a new Files tab on the
/// home folder; a user run selects it, automation opens it without moving focus.
/// Open Files as Pane (classic's right sidebar Files tool as a pane) opens the
/// same Files tab on the focused terminal's folder, or the CLI's `--pane` or `--path`.
enum FilesPaneHandlers {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let services = context.services
        services.pages.register(services.viewers.filesPanes)
        registry.bind("files.open", run: { invocation in
            try services.viewers.filesPanes.open(focus: invocation.allowsViewChange)
        })
        registry.bind("palette.openFilesPane", run: { invocation in
            guard let folder = context.openAsPaneFolder(invocation) else { return }
            try services.viewers.filesPanes.open(folder: folder, focus: invocation.allowsViewChange)
        })
    }
}
