import AppKit
import CmuxNextActions
import CmuxNextPages

/// The diff viewer (diff-host.md S4): the 11 `diffViewer*` navigation
/// actions send their page command (``DiffPageCommand/forAction``) to the
/// focused diff tab; their keys stay in the one key dispatcher, which offers
/// them only while a diff tab has the keyboard (`diffViewerFocused`). The open
/// actions (`openDiffViewer`, `palette.openDirectoryDiffViewer`) have one path,
/// `ViewerHandlers` (R89): the focused pane's repository through
/// ``DiffPageService/open(folder:source:in:focus:)``, else the cmux picker.
enum DiffHandlers {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let service = context.services.diffPages
        context.services.pages.register(service)
        for (action, command) in DiffPageCommand.forAction {
            registry.bind(ActionID(rawValue: action), run: { invocation in
                guard let tab = context.scope(invocation).tab, let page = service.pageView(tab.id.rawValue) else {
                    throw ActionFailure(message: DiffPageStrings.noDiffTab)
                }
                page.send(command: command)
            })
        }
    }
}
