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

/// The crash page's Reload All Tabs after the Chromium Host ended (`browser.crashPage.reloadAllTabs`,
/// behavior audit 4, P8), the other button of the page status views. The page's own button routes through it
/// (``installPageStatusRouters(on:registry:)``), so a click and the palette take one path. The handler only
/// marks and asks: each shown tab's Reload starts or joins the host's restart off the main actor, and each
/// hidden one reloads when it shows.
extension CertificateWarningHandlers {
    static let reloadAllTabsID: ActionID = "browser.crashPage.reloadAllTabs"

    static func bindCrashPage(into registry: ActionRegistry, context: AppActionContext) {
        let engine = { context.services.cache.chromium.built }
        registry.bindEffect(reloadAllTabsID, unavailable: {
            engine()?.hasTabsTheHostEndLeft == true ? nil : noTabWaits
        }, effect: { _ in
            guard let engine = engine(), engine.hasTabsTheHostEndLeft else { return .refused(noTabWaits) }
            engine.reloadTabsTheHostEndLeft()
            return .done
        })
    }

    /// The page status views' buttons run their actions: the certificate warning's
    /// (``installRouter(on:registry:)``) and the crash page's Reload All Tabs.
    static func installPageStatusRouters(on entry: BrowserEntry, registry: ActionRegistry) {
        installRouter(on: entry, registry: registry)
        entry.chrome.crashPageReloadAllRouter = { [weak registry] in
            registry?.perform(reloadAllTabsID) ?? false
        }
    }

    /// Why Reload All Tabs cannot run now.
    static var noTabWaits: String {
        String(localized: "action.crashPage.reloadAllTabs.unavailable",
               defaultValue: "No tab is waiting for Chromium to start again.", bundle: .module)
    }
}
