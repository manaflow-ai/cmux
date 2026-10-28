import CmuxNextActions

/// `passwords.open` (the palette's Passwords): Chromium's own password manager
/// (`chrome://password-manager`) in a Chromium tab of the focused pane, in the
/// browser profile a new tab there gets; the same page Settings > Browser >
/// Autofill and passwords opens (`browserProfile.managePasswords`).
enum PasswordHandlers {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let page = PasswordsPageService(services: context.services)
        context.services.pages.register(page)
        registry.bind("passwords.open", run: { invocation in
            try BrowserProfileOpenHandlers.openAutofillPage(.passwords, invocation, context: context)
        })
    }
}
