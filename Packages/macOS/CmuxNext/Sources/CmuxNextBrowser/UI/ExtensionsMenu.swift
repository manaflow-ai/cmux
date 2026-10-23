public import AppKit

/// What an Extensions menu item does.
public enum ExtensionMenuOperation: String, CaseIterable, Sendable {
    case run, pin, unpin, options, enable, disable, reload, remove, siteAccess, loadUnpacked, webStore, manage
    /// The extension's home page (its name at the top of its context menu).
    case homePage
    /// chrome://extensions with the extension's details ("Manage Extension").
    case manageExtension
    /// The site settings of the extension's origin ("View Web Permissions").
    case webPermissions
}

/// Runs Extensions menu items. The App routes them through its action
/// registry (so the menu, palette, shortcuts and CLI share one handler per
/// action); `ExtensionsMenu.DirectHandler` drives the store itself for
/// standalone use.
public protocol ExtensionMenuHandling: AnyObject {
    func title(for operation: ExtensionMenuOperation) -> String
    func perform(_ operation: ExtensionMenuOperation, extensionID: String?)
}

/// The Extensions (puzzle) bubble's names and lists, shared by the bubble
/// (``ExtensionsMenuController``), the toolbar and the App: Chrome's legacy
/// Extensions menu lists the enabled extensions by name, each with its
/// action, a pin button and a "more options" button with its context menu
/// (``ExtensionContextMenuModel``), then Manage Extensions.
public struct ExtensionsMenu {
    /// Creates the menu operations used by this browser UI.
    public init() {}

    /// Accessibility identifiers (UI automation and the extension e2e suite).
    public static let menuIdentifier = "browser.extensions.menu"
    public static func rowIdentifier(_ id: String) -> String { "browser.extensions.menu.row.\(id)" }
    public static func pinIdentifier(_ id: String) -> String { "browser.extensions.menu.pin.\(id)" }
    public static func moreIdentifier(_ id: String) -> String { "browser.extensions.menu.more.\(id)" }
    public static func sidePanelIdentifier(_ id: String) -> String { "browser.extensions.menu.sidePanel.\(id)" }
    public static func footerIdentifier(_ operation: ExtensionMenuOperation) -> String { "browser.extensions.menu.\(operation.rawValue)" }

    public func defaultTitle(_ operation: ExtensionMenuOperation) -> String { Strings.extensionMenuTitle(operation) }

    /// The extensions the bubble lists: the store's enabled ones (Chrome's
    /// toolbar model lists only enabled extensions), or the toolbar actions
    /// on a fork without the management API. In the store's (name) order.
    func extensions(of host: any BrowserExtensionActionHosting) -> [BrowserExtensionInfo] {
        let store = host.extensionStore
        let list = store.extensions.isEmpty ? BrowserExtensionInfo.fromActions(host.extensionActions) : store.extensions
        return list.filter(\.isEnabled)
    }

    /// One extension's context menu (a right click on its toolbar icon, or
    /// its "more options" button in the bubble), in Chrome's order.
    public func itemMenu(for info: BrowserExtensionInfo, supportsManagement: Bool,
                         handler: any ExtensionMenuHandling, fromToolbar: Bool = true) -> NSMenu {
        ExtensionContextMenuModel(info: info, supportsManagement: supportsManagement,
                                  source: fromToolbar ? .toolbarAction : .menuItem)
            .menu(extensionID: info.id, title: info.name, handler: handler)
    }

    /// Drives the store and the tab directly (standalone module use).
    public final class DirectHandler: ExtensionMenuHandling {
        private weak var host: (any BrowserExtensionActionHosting)?
        private let open: (URL) -> Void

        public init(host: any BrowserExtensionActionHosting, open: @escaping (URL) -> Void) {
            self.host = host
            self.open = open
        }

        public func title(for operation: ExtensionMenuOperation) -> String { Strings.extensionMenuTitle(operation) }

        public func perform(_ operation: ExtensionMenuOperation, extensionID: String?) {
            guard let host else { return }
            let store = host.extensionStore
            let id = extensionID ?? ""
            switch operation {
            case .run: host.requestExtensionAction(id)
            case .pin: _ = store.setPinned(id, true)
            case .unpin: _ = store.setPinned(id, false)
            case .options: _ = store.openOptions(id, from: host as? any BrowserTab)
            case .enable: _ = store.setEnabled(id, true)
            case .disable: _ = store.setEnabled(id, false)
            case .remove: _ = store.uninstall(id)
            case .reload: _ = store.reload(id)
            case .siteAccess: host.showExtensionActionMenu(id, atScreenPoint: NSEvent.mouseLocation)
            case .loadUnpacked: break
            case .webStore: open(URL.browserExtensionWebStore)
            case .manage: open(URL.browserExtensionManagement)
            case .homePage: open(URL.browserExtensionWebStoreItem(id))
            case .manageExtension: open(URL.browserExtensionDetails(id))
            case .webPermissions: open(URL.browserExtensionWebPermissions(id))
            }
        }
    }
}
