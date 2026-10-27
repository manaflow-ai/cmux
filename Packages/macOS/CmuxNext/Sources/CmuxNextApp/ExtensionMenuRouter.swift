import struct CmuxSafeConcurrency.OwnerReference
import AppKit
import CmuxNextActions
import CmuxNextBrowser

/// The Extensions (puzzle) menu of one browser tab: its items are the
/// `browser.extension*` registry actions, targeted at the tab, so the
/// menu, palette, shortcuts and CLI share one handler per action.
final class ExtensionMenuRouter: ExtensionMenuHandling {
    private let servicesReference: OwnerReference<AppServices>
    /// The app's services, which own this; nil (reported) only once they are gone.
    private var services: AppServices? { servicesReference.resolve() }
    private let tabKey: String

    init(services: AppServices, tabKey: String) {
        servicesReference = OwnerReference(services: services)
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
        case .siteAccess, .homePage, .manageExtension, .webPermissions: nil
        }
    }

    /// The page an extension's context menu opens: its home page, its details in
    /// chrome://extensions, or its origin's site settings. Nil for other operations.
    static func page(for operation: ExtensionMenuOperation, extensionID id: String) -> URL? {
        switch operation {
        case .homePage: URL.browserExtensionWebStoreItem(id)
        case .manageExtension: URL.browserExtensionDetails(id)
        case .webPermissions: URL.browserExtensionWebPermissions(id)
        default: nil
        }
    }

    func title(for operation: ExtensionMenuOperation) -> String {
        // The menu row already names the extension: short verbs read better
        // than the palette's full titles.
        ExtensionsMenu().defaultTitle(operation)
    }

    func perform(_ operation: ExtensionMenuOperation, extensionID: String?) {
        guard let services else { return }
        if operation == .siteAccess {
            // Chromium's own action menu (site access, pin, options, remove).
            if let id = extensionID, let entry = services.cache.existingBrowser(tabKey),
               let host = entry.tab as? any BrowserExtensionActionHosting {
                host.showExtensionActionMenu(id, atScreenPoint: NSEvent.mouseLocation)
            }
            return
        }
        if let id = extensionID, let url = Self.page(for: operation, extensionID: id) {
            // Chrome opens these pages in a new foreground tab.
            let invocation = ActionInvocation(target: ActionTargetRef(kind: .tab, id: tabKey))
            AppActions.scope(services, invocation).pane?.newBrowserTab(url: url, engine: BrowserEngineTag.cef.rawValue)
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
