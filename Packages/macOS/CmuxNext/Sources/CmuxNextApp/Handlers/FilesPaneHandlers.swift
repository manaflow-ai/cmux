import CmuxNextActions

/// Files pane actions (u2360): `files.open` opens a new Files tab on the
/// home folder; a user run selects it, automation opens it without moving focus.
enum FilesPaneHandlers {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let services = context.services
        services.pages.register(services.viewers.filesPanes)
        registry.bind("files.open", run: { invocation in
            try services.viewers.filesPanes.open(focus: invocation.allowsViewChange)
        })
    }
}
