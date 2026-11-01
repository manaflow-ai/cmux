public import AppKit

extension ActionRegistry {
    /// `context`'s menu as the person arranged it (``contextMenuLayouts``) without `hidden` rows,
    /// inside folders too. Call-site filters (a page tab hides terminal themes) apply after the
    /// arrangement, so a promoted row a target does not offer still leaves.
    public func contextMenuEntries(for context: ActionMenuContext, removing hidden: Set<ActionID> = []) -> [ContextMenuEntry] {
        let generated = ContextMenuCatalog.shared.entries(for: context)
        let arranged = contextMenuLayouts[context].map { $0.applied(to: generated) } ?? generated
        return hidden.isEmpty ? arranged : ContextMenuCatalog.removing(hidden, from: arranged)
    }

    /// The cmux rows after an engine's own page menu (``ContextMenuCatalog/browserPageAfterEngineMenu``),
    /// as the person arranged the page menu.
    public var browserPageAfterEngineMenu: [ContextMenuEntry] {
        ContextMenuCatalog.afterEngineMenu(contextMenuEntries(for: .browserPage))
    }

    /// Customize Menu…, which opens Settings > Menus on `context`; nil when the person turned the
    /// row off or no App installed ``customizeMenu``.
    public func customizeMenuItem(for context: ActionMenuContext) -> NSMenuItem? {
        guard showsCustomizeMenuItem, let open = customizeMenu else { return nil }
        let handler = CustomizeMenuHandler { open(context) }
        let item = NSMenuItem(title: Self.customizeMenuTitle, action: #selector(CustomizeMenuHandler.run(_:)), keyEquivalent: "")
        // NSMenuItem holds its target weakly: the item keeps the handler alive.
        item.target = handler
        item.representedObject = handler
        item.image = Self.menuIcon("slider.horizontal.3")
        return item
    }

    /// Ends `menu` with Customize Menu… after a separator (``customizeMenuItem(for:)``).
    public func appendCustomizeItem(to menu: NSMenu, for context: ActionMenuContext) {
        guard menu.items.contains(where: { !$0.isSeparatorItem }), let item = customizeMenuItem(for: context) else { return }
        if menu.items.last?.isSeparatorItem == false { menu.addItem(.separator()) }
        menu.addItem(item)
    }

    /// The menu and index of the row that runs `id` in `menu` or any of its submenus: a row the
    /// person moved into More (Settings > Menus) is found there too.
    public static func locate(_ id: ActionID, in menu: NSMenu) -> (menu: NSMenu, index: Int)? {
        if let index = menu.items.firstIndex(where: { menuRun(of: $0)?.id == id }) { return (menu, index) }
        for case let submenu? in menu.items.map(\.submenu) {
            if let found = locate(id, in: submenu) { return found }
        }
        return nil
    }

    /// Whether `item` is a Customize Menu… row (tests, and menus that move rows between menus).
    public static func isCustomizeItem(_ item: NSMenuItem) -> Bool {
        item.representedObject is CustomizeMenuHandler
    }

    static var customizeMenuTitle: String {
        String(localized: "menu.customize", defaultValue: "Customize Menu…", bundle: .module)
    }
}

/// Runs Customize Menu…'s open on a click.
private final class CustomizeMenuHandler: NSObject {
    private let open: @MainActor () -> Void

    init(_ open: @escaping @MainActor () -> Void) {
        self.open = open
    }

    @MainActor @objc func run(_ sender: Any?) {
        open()
    }
}
