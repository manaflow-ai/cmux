public import AppKit

/// What an Extensions menu item does.
public enum ExtensionMenuOperation: String, CaseIterable, Sendable {
    case run, pin, unpin, options, enable, disable, remove, siteAccess, loadUnpacked, webStore, manage
}

/// Runs Extensions menu items. The App routes them through its action
/// registry (so the menu, palette, shortcuts and CLI share one handler per
/// action); `ExtensionsMenu.DirectHandler` drives the store itself for
/// standalone use.
public protocol ExtensionMenuHandling: AnyObject {
    func title(for operation: ExtensionMenuOperation) -> String
    func perform(_ operation: ExtensionMenuOperation, extensionID: String?)
}

/// Chrome's Extensions (puzzle) menu: one row per installed extension
/// (click runs its action, a pin toggle, a "more" button with the
/// per-extension menu), then Manage Extensions, Chrome Web Store and Load
/// Unpacked. Enabled extensions come first, in Chromium's name order.
public enum ExtensionsMenu {
    /// Accessibility identifiers (UI automation and the extension e2e suite).
    public enum Identifier {
        public static let menu = "browser.extensions.menu"
        public static func row(_ id: String) -> String { "browser.extensions.menu.row.\(id)" }
        public static func pin(_ id: String) -> String { "browser.extensions.menu.pin.\(id)" }
        public static func more(_ id: String) -> String { "browser.extensions.menu.more.\(id)" }
        public static func footer(_ operation: ExtensionMenuOperation) -> String { "browser.extensions.menu.\(operation.rawValue)" }
    }

    public static func defaultTitle(_ operation: ExtensionMenuOperation) -> String { Strings.extensionMenuTitle(operation) }

    /// The extensions the menu lists: the store's, or the toolbar actions on
    /// a fork without the management API.
    static func extensions(of host: any BrowserExtensionActionHosting) -> [BrowserExtensionInfo] {
        let store = host.extensionStore
        let list = store.extensions.isEmpty ? BrowserExtensionInfo.fromActions(host.extensionActions) : store.extensions
        return list.filter { $0.isEnabled } + list.filter { !$0.isEnabled }
    }

    /// The menu for `host`. Row clicks close the menu and hand their work
    /// to `afterClose`, which runs it once the menu's tracking loop ended
    /// (a popup or a second menu must not open inside it); `presentItemMenu`
    /// shows a row's per-extension menu.
    public static func make(for host: any BrowserExtensionActionHosting, handler: any ExtensionMenuHandling,
                            afterClose: @escaping (@escaping () -> Void) -> Void,
                            presentItemMenu: @escaping (NSMenu) -> Void) -> NSMenu {
        let menu = NSMenu(title: Strings.extensions)
        menu.autoenablesItems = false
        menu.identifier = NSUserInterfaceItemIdentifier(Identifier.menu)
        let store = host.extensionStore
        let icons = Dictionary(host.extensionActions.map { ($0.id, $0.iconPNG) }, uniquingKeysWith: { first, _ in first })
        let list = extensions(of: host)
        if list.isEmpty {
            let empty = NSMenuItem(title: Strings.noExtensions, action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        for info in list {
            let item = NSMenuItem(title: info.name, action: nil, keyEquivalent: "")
            item.representedObject = info.id
            let row = ExtensionMenuRowView(
                info: info, icon: image(for: info, png: icons[info.id] ?? nil),
                canPin: info.isEnabled && info.hasAction && store.supportsManagement
            )
            row.onRun = { [weak handler, weak menu] in
                menu?.cancelTracking()
                afterClose { handler?.perform(info.isEnabled && info.hasAction ? .run : .siteAccess, extensionID: info.id) }
            }
            // Pinning keeps the menu open, as in Chrome.
            row.onPin = { [weak handler] in handler?.perform(info.isPinned ? .unpin : .pin, extensionID: info.id) }
            row.onMore = { [weak handler, weak menu] in
                menu?.cancelTracking()
                afterClose {
                    guard let handler else { return }
                    presentItemMenu(itemMenu(for: info, supportsManagement: store.supportsManagement, handler: handler))
                }
            }
            item.view = row
            menu.addItem(item)
        }
        menu.addItem(.separator())
        var footer: [ExtensionMenuOperation] = [.manage, .webStore]
        if store.supportsManagement { footer.append(.loadUnpacked) }
        for operation in footer {
            let item = self.item(handler.title(for: operation), operation, nil, handler)
            item.identifier = NSUserInterfaceItemIdentifier(Identifier.footer(operation))
            item.image = NSImage(systemSymbolName: symbol(for: operation), accessibilityDescription: nil)
            menu.addItem(item)
        }
        return menu
    }

    /// The operations that apply to one extension, in menu order.
    public static func operations(for info: BrowserExtensionInfo, supportsManagement: Bool) -> [ExtensionMenuOperation] {
        var operations: [ExtensionMenuOperation] = []
        if info.isEnabled && info.hasAction { operations.append(.run) }
        if info.isEnabled && info.hasAction && supportsManagement { operations.append(info.isPinned ? .unpin : .pin) }
        if info.isEnabled && info.optionsURL != nil { operations.append(.options) }
        if supportsManagement && info.canToggle { operations.append(info.isEnabled ? .disable : .enable) }
        if info.isEnabled && info.hasAction { operations.append(.siteAccess) }
        if supportsManagement && info.canRemove { operations.append(.remove) }
        return operations
    }

    /// One extension's menu (the row's "more" button and a right click on
    /// its toolbar button).
    public static func itemMenu(for info: BrowserExtensionInfo, supportsManagement: Bool,
                                handler: any ExtensionMenuHandling) -> NSMenu {
        let menu = NSMenu(title: info.name)
        menu.autoenablesItems = false
        menu.identifier = NSUserInterfaceItemIdentifier(Identifier.more(info.id))
        let header = NSMenuItem(title: info.name, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())
        for operation in operations(for: info, supportsManagement: supportsManagement) {
            if operation == .remove || operation == .siteAccess { menu.addItem(.separator()) }
            let item = self.item(handler.title(for: operation), operation, info.id, handler)
            item.identifier = NSUserInterfaceItemIdentifier("\(Identifier.more(info.id)).\(operation.rawValue)")
            menu.addItem(item)
        }
        return menu
    }

    private static func symbol(for operation: ExtensionMenuOperation) -> String {
        switch operation {
        case .manage: "gearshape"
        case .webStore: "bag"
        case .loadUnpacked: "folder.badge.plus"
        default: "puzzlepiece.extension"
        }
    }

    private static func item(_ title: String, _ operation: ExtensionMenuOperation, _ id: String?,
                             _ handler: any ExtensionMenuHandling) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(ClosureMenuTarget.run), keyEquivalent: "")
        let target = ClosureMenuTarget { [weak handler] in handler?.perform(operation, extensionID: id) }
        item.target = target
        item.representedObject = target
        return item
    }

    static func image(for info: BrowserExtensionInfo, png: Data?) -> NSImage? {
        let image = png.flatMap(NSImage.init(data:))
            ?? info.iconPath.flatMap(NSImage.init(contentsOfFile:))
            ?? NSImage(systemSymbolName: "puzzlepiece.extension", accessibilityDescription: info.name)
        image?.size = NSSize(width: 16, height: 16)
        return image
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
            case .siteAccess: host.showExtensionActionMenu(id, atScreenPoint: NSEvent.mouseLocation)
            case .loadUnpacked: break
            case .webStore: open(BrowserExtensionLinks.webStore)
            case .manage: open(BrowserExtensionLinks.manage)
            }
        }
    }
}
