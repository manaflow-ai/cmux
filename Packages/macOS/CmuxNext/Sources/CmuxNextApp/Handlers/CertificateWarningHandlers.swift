import AppKit
import CmuxNextActions
import CmuxNextBrowser

/// The certificate warning page's Proceed and Go Back
/// (`browser.certificateWarning.*`). Each handler runs the matching
/// `CertificateWarningCommand` on the targeted page; the page's own buttons
/// route through these (`installRouter`), so a click, a shortcut, the palette
/// and `cmux action run` share one path. Disabled unless the page shows the
/// warning.
enum CertificateWarningHandlers {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        for command in CertificateWarningCommand.allCases {
            let id = ActionID(rawValue: command.actionID)
            let reason: @MainActor (ActionInvocation) -> String? = { invocation in
                guard let entry = try? context.page(invocation) else { return nil }
                return command.unavailableReason(on: entry.tab)
            }
            registry.bind(id, unavailable: { reason(ActionInvocation()) }, run: { invocation in
                let entry = try context.page(invocation)
                if let refusal = command.unavailableReason(on: entry.tab) { throw ActionFailure(message: refusal) }
                command.perform(on: entry.tab)
            })
            // An explicit target (the warning page's own tab).
            ActionTargetReasons.set(id, in: registry, reason)
        }
    }

    /// The warning page's buttons run their action, targeted at the page's
    /// own tab (it may not be the focused pane's).
    static func installRouter(on entry: BrowserEntry, registry: ActionRegistry) {
        let tabID = entry.tab.id.rawValue
        entry.chrome.certificateWarningRouter = { [weak registry] command in
            guard let registry else { return false }
            let invocation = ActionInvocation(target: ActionTargetRef(kind: .tab, id: tabID))
            return registry.perform(ActionID(rawValue: command.actionID), invocation: invocation)
        }
    }
}
