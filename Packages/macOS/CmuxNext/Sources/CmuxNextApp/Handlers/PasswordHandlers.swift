import CmuxNextActions

/// The Passwords page (plans/cmux-next/passwords.md 1.4): `passwords.open` shows its page tab.
/// The action is person-only, so only the palette (a person) runs it.
enum PasswordHandlers {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let page = PasswordsPageService(services: context.services)
        context.services.pages.register(page)
        registry.bind("passwords.open", run: { invocation in
            try page.open(focus: invocation.allowsViewChange)
        })
    }
}
