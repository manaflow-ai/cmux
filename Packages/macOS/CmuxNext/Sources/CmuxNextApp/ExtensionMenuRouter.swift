import AppKit
import CmuxNextActions
import CmuxNextBrowser

/// The Extensions (puzzle) menu of one browser tab: its items are the
/// `browser.extension*` registry actions, targeted at the tab, so the
/// menu, palette, shortcuts and CLI share one handler per action.
final class ExtensionMenuRouter: ExtensionMenuHandling {
    private unowned let services: AppServices
    private let tabKey: String

    init(services: AppServices, tabKey: String) {
        self.services = services
        self.tabKey = tabKey
    }

    static func actionID(for operation: ExtensionMenuOperation) -> ActionID? {
        switch operation {
        case .run: "browser.extension.run"
        case .pin: "browser.extension.pin"
        case .unpin: "browser.extension.unpin"
        case .options: "browser.extension.options"
        case .enable: "browser.extension.enable"
        case .disable: "browser.extension.disable"
        case .remove: "browser.extension.remove"
        case .reload: "browser.extension.reload"
        case .loadUnpacked: "browser.extensions.loadUnpacked"
        case .webStore: "browser.extensions.webStore"
        case .manage: "browser.extensions.manage"
        case .siteAccess: nil
        }
    }

    func title(for operation: ExtensionMenuOperation) -> String {
        // The menu row already names the extension: short verbs read better
        // than the palette's full titles.
        ExtensionsMenu().defaultTitle(operation)
    }

    func perform(_ operation: ExtensionMenuOperation, extensionID: String?) {
        if operation == .siteAccess {
            // Chromium's own action menu (site access, pin, options, remove).
            if let id = extensionID, let entry = services.cache.existingBrowser(tabKey),
               let host = entry.tab as? any BrowserExtensionActionHosting {
                host.showExtensionActionMenu(id, atScreenPoint: NSEvent.mouseLocation)
            }
            return
        }
        guard let id = Self.actionID(for: operation) else { return }
        var arguments: [String: ActionValue] = [:]
        if let extensionID { arguments["extension"] = .string(extensionID) }
        // The tab itself, not its pane: the pane's selected content is not
        // always this page (a pane shown in two windows, an adopted page), which
        // refused the menu's rows with "needs a Chromium tab".
        let target = ActionTargetRef(kind: .tab, id: tabKey)
        services.registry.perform(id, invocation: ActionInvocation(target: target, arguments: arguments))
    }
}
