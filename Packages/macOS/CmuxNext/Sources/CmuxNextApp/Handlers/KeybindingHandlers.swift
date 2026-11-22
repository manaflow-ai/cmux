import CmuxNextActions

/// The Keyboard Shortcuts editor (R59 slice 7): `keybindings.open` shows
/// its page tab; a user run focuses it, automation opens it without moving
/// focus.
enum KeybindingHandlers {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let page = KeybindingsPageService(services: context.services)
        context.services.pages.register(page)
        registry.bind("keybindings.open", run: { invocation in
            try page.open(focus: invocation.allowsViewChange)
        })
    }
}
