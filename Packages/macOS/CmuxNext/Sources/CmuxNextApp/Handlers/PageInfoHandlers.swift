import AppKit
import CmuxNextActions
import CmuxNextBrowser

/// Page Info actions (the omnibar's "View site information" bubble). Each
/// handler runs the matching `PageInfoCommand` on the targeted page; the
/// bubble's own controls route through these (`installRouter`), so a click,
/// the palette, a context menu and `cmux browser page-info …` share one path.
enum PageInfoHandlers {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        for id in PageInfoCommand.actionIDs {
            registry.bind(ActionID(rawValue: id), run: { invocation in
                let entry = try context.page(invocation)
                var arguments: [String: String] = [:]
                for (name, value) in invocation.arguments {
                    if let text = value.stringValue { arguments[name] = text }
                }
                do throws(PageInfoCommandError) {
                    try entry.chrome.pageInfo.run(PageInfoCommand.from(actionID: id, arguments: arguments))
                } catch {
                    throw ActionFailure(message: error.message)
                }
            })
        }
    }

    /// Bubble controls run their registry action, targeted at the bubble's
    /// own tab (it may not be the focused pane's).
    static func installRouter(on entry: BrowserEntry, registry: ActionRegistry) {
        let tabID = entry.tab.id.rawValue
        entry.chrome.pageInfo.commandRouter = { [weak registry] command in
            guard let registry, let action = command.action else { return false }
            let invocation = ActionInvocation(
                target: ActionTargetRef(kind: .tab, id: tabID),
                arguments: action.arguments.mapValues { .string($0) }
            )
            return registry.perform(ActionID(rawValue: action.id), invocation: invocation)
        }
    }
}
