import CmuxNextActions
import CmuxNextPages

/// Actions that drive a React page through its host commands
/// (`cmux.page.command`, plans/cmux-next/keybindings.md 4.2): the page
/// handles no chords itself; the key dispatcher resolves the action and this
/// sends the page command to the focused page that declares it. The
/// markdown page's save and zoom (`MarkdownPageCommand.forAction`).
enum PageCommandHandlers {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let services = context.services
        for (action, command) in MarkdownPageCommand.forAction {
            registry.bind(ActionID(rawValue: action), run: { _ in
                guard let controller = services.windows.active, let router = services.keyRouter,
                      let page = router.focusedPage(in: controller), page.descriptor.commands.contains(command),
                      page.send(command: command) else {
                    throw ActionFailure(message: FilePageStrings.noFilePage)
                }
            })
        }
    }
}
