public import AppKit

extension ActionRegistry {
    /// Renders the declared right-click menu for `context`
    /// (`ContextMenuCatalog`). Actions that do not apply are hidden; unbound
    /// or disabled ones are shown disabled; runs of separators collapse.
    /// Items pass `target` to the handler. `implied` adds focus facts the
    /// target itself establishes (a right-clicked browser tab is a browser
    /// even while a terminal has focus).
    public func makeContextMenu(
        for context: ActionMenuContext,
        target: ActionTargetRef? = nil,
        entries: [ContextMenuEntry]? = nil,
        implied: ActionContext = []
    ) -> NSMenu {
        let effective = self.context.union(Self.impliedContext(for: context)).union(implied)
        let menu = NSMenu()
        menu.autoenablesItems = true
        for item in menuItems(entries ?? ContextMenuCatalog.shared.entries(for: context), target: target, context: effective) {
            menu.addItem(item)
        }
        return menu
    }

    /// Items for one main menu: every action whose `mainMenu` is `menu`, in
    /// catalog order, with a separator between categories.
    public func makeMainMenuItems(for menu: ActionMainMenu) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        var lastCategory: ActionCategory?
        for descriptor in descriptors where descriptor.mainMenu == menu {
            if let lastCategory, lastCategory != descriptor.category { items.append(.separator()) }
            lastCategory = descriptor.category
            if let item = makeMenuItem(for: descriptor.id) { items.append(item) }
        }
        return items
    }

    /// Focus facts a right-click implies (right-clicking a page means a
    /// browser is the target even if a terminal has focus).
    static func impliedContext(for context: ActionMenuContext) -> ActionContext {
        switch context {
        case .browserPage: .browserFocused
        case .terminalSelection: .terminalFocused
        default: []
        }
    }

    private func menuItems(_ entries: [ContextMenuEntry], target: ActionTargetRef?, context: ActionContext) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        for entry in entries {
            switch entry {
            case .separator:
                if let last = items.last, !last.isSeparatorItem { items.append(.separator()) }
            case .action(let id):
                guard let descriptor = descriptor(for: id), allowsByPolicy(descriptor), Self.isAvailable(descriptor, in: context),
                      let item = makeMenuItem(for: id)
                else { continue }
                item.representedObject = ActionMenuPayload(id: descriptor.id, target: target)
                // Context menus are built per click, so a disabled entry can
                // say why (Chromium in a build without CEF).
                if let reason = ActionTargetReasons.reason(for: descriptor.id, invocation: ActionInvocation(target: target), in: self) {
                    item.subtitle = reason
                    item.toolTip = reason
                }
                items.append(item)
            case .submenu(let id, let children):
                let childItems = menuItems(children, target: target, context: context)
                guard !childItems.isEmpty, let title = title(for: id) else { continue }
                let item = NSMenuItem(title: title.hasSuffix("…") ? String(title.dropLast()) : title, action: nil, keyEquivalent: "")
                let submenu = NSMenu(title: item.title)
                childItems.forEach(submenu.addItem)
                item.submenu = submenu
                items.append(item)
            case .folder(let folder, let children):
                let childItems = menuItems(children, target: target, context: context)
                guard childItems.contains(where: { !$0.isSeparatorItem }) else { continue }
                let item = NSMenuItem(title: folder.title, action: nil, keyEquivalent: "")
                let submenu = NSMenu(title: folder.title)
                childItems.forEach(submenu.addItem)
                item.submenu = submenu
                items.append(item)
            case .choices(let id):
                guard let descriptor = descriptor(for: id), allowsByPolicy(descriptor), Self.isAvailable(descriptor, in: context),
                      let item = makeChoicesItem(for: descriptor, target: target)
                else { continue }
                items.append(item)
            }
        }
        while items.last?.isSeparatorItem == true { items.removeLast() }
        return items
    }
}
