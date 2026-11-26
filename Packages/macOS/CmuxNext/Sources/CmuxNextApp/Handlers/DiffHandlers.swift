import AppKit
import CmuxNextActions
import CmuxNextBridge
import CmuxNextDiff
import CmuxNextPages

/// The diff viewer (diff-host.md S4): the `diffViewer*` actions send their page
/// command (``DiffPageCommand/forAction``) to the focused or targeted diff tab's
/// page, found by its provider key (a page tab's strip id is not its key); the
/// key dispatcher offers their keys only while a diff tab has the keyboard. The open
/// actions (`openDiffViewer`, `palette.openDirectoryDiffViewer`) have one path,
/// `ViewerHandlers` (R89): the focused pane's repository through
/// ``DiffPageService/open(folder:source:in:focus:)``, else the cmux picker.
enum DiffHandlers {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let service = context.services.viewers.diffPages
        context.services.pages.register(service)
        AgentTurnStateStore.shared.turnEndedObservers.append { [weak service, weak services = context.services] session, folder in services?.paneOwedWork.owe(session: session, "diffWarm", in: services?.madeAgentTabs.map { Array($0.views.values) + $0.standaloneViews.allObjects } ?? []) { service?.warm(folder: folder) } } // a turn ended: its repository's diff is precomputed once someone can see the chat
        for (action, command) in DiffPageCommand.forAction {
            registry.bind(ActionID(rawValue: action), run: { invocation in
                guard let tab = context.scope(invocation).tab, let page = service.pageView(FilePageHandlers.providerKey(tab.id.rawValue, context.services)) else {
                    throw ActionFailure(message: DiffPageStrings.noDiffTab)
                }
                page.send(command: command)
            })
        }
    }
}
