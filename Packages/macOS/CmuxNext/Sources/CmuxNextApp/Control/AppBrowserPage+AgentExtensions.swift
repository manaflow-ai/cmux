import CmuxNextBrowser
import CmuxNextControl
import Foundation

/// Interim rule until fork P6 blocks extensions per tab: agent page
/// operations refuse a tab whose profile has an enabled extension that can
/// reach the page, unless the person allowed agents in that tab
/// (plans/cmux-next/passwords.md, section 3.4). The browser host's CDP relay
/// applies the same rule from the provider's `tab.access` frame.
extension AppBrowserPage {
    static func agentExtensionRefusal(_ operation: BrowserPageOperation, target: URL?, page: any BrowserTab,
                                      allowedByPerson: Bool, access: AgentExtensionAccess) -> ControlError? {
        guard !allowedByPerson, operation != .state, let store = (page as? any BrowserExtensionActionHosting)?.extensionStore else { return nil }
        store.refresh()
        var urls: [URL?] = []
        switch operation {
        case .navigate: urls = [target]
        case .back, .forward:
            urls = [page.state.url]
            if let list = (page as? any BrowserBackForwardListing)?.navigationList() {
                let index = list.current + (operation == .back ? -1 : 1)
                if list.entries.indices.contains(index) { urls.append(list.entries[index].url) }
            }
        case .reload, .evaluate, .state: urls = [page.state.url]
        }
        var names: [String] = []
        for url in urls {
            for blocker in access.blockers(store.extensions, url: url) where !names.contains(blocker.name) { names.append(blocker.name) }
        }
        guard !names.isEmpty else { return nil }
        return ControlError(
            code: "forbidden",
            message: "the tab's profile has an enabled extension with access to this page; open the tab with openBrowser profile \"agent\" (a profile without extensions), or ask the person to allow agents in this tab",
            data: .object([
                "reason": .string("extension_host_access"),
                "extensions": .array(names.map { .string($0) }),
            ])
        )
    }
}
