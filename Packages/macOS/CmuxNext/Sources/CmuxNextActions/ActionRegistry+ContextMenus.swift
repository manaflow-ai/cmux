public import AppKit

extension ActionRegistry {
    /// Renders the declared right-click menu for `context`
    /// (`ContextMenuCatalog`). Actions that do not apply are hidden; unbound
    /// or disabled ones are shown disabled; runs of separators collapse.
    /// Items pass `target` to the handler. `implied` adds focus facts the
    /// target itself establishes (a right-clicked browser tab is a browser
    /// even while a terminal has focus); they only show rows. The menu's own
    /// facts (`impliedContext(for:)`) also enable and run its items
    /// (`ActionMenuPayload.implied`): a Files row runs the explorer's actions
    /// while a terminal has the keyboard. `arguments` go to every item's run
    /// (a right-clicked link's `url`). Without `entries` the menu is the person's
    /// arrangement (``contextMenuEntries(for:removing:)``). `customize` ends it with
    /// Customize Menu…; nil does so for a whole menu (no `entries`), not for rows a caller
    /// takes into another menu. `machineID` names the machine that owns `target` (a forked or SSH
    /// machine keeps its ids): every row is shown, titled and run against that machine only.
    public func makeContextMenu(
        for context: ActionMenuContext,
        target: ActionTargetRef? = nil,
        entries: [ContextMenuEntry]? = nil,
        implied: ActionContext = [],
        arguments: [String: ActionValue] = [:],
        customize: Bool? = nil,
        machineID: String? = nil
    ) -> NSMenu {
        let runFacts = Self.impliedContext(for: context)
        let effective = self.context.union(runFacts).union(implied)
        let menu = NSMenu()
        menu.autoenablesItems = true
        let shown = entries ?? contextMenuEntries(for: context), labels = ContextMenuCatalog.shared.labels(for: context)
        menuItems(shown, target: target, context: effective, implied: runFacts, arguments: arguments, labels: labels,
                  machineID: machineID).forEach(menu.addItem)
        if customize ?? (entries == nil) { appendCustomizeItem(to: menu, for: context) }
        return menu
    }

    /// One row of `context`'s menu whose arguments are known only when the menu opens (Open
    /// With's apps, one row per app): it runs `id` with `arguments` and the menu's facts, like
    /// a catalog row. Nil when `id` is not in the catalog or an administrator turned it off.
    public func makeContextMenuItem(for id: ActionID, in context: ActionMenuContext, target: ActionTargetRef? = nil,
                                    arguments: [String: ActionValue] = [:], title: String? = nil) -> NSMenuItem? {
        guard let descriptor = descriptor(for: id), ActionFeature.turnedOff(descriptor, in: disabledFeatures) == nil,
              let item = makeMenuItem(for: id) else { return nil }
        item.representedObject = ActionMenuPayload(id: descriptor.id, target: target, arguments: arguments,
                                                   implied: Self.impliedContext(for: context))
        item.keyEquivalent = ""
        item.keyEquivalentModifierMask = []
        if let title { item.title = title }
        return item
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
    nonisolated static func impliedContext(for context: ActionMenuContext) -> ActionContext {
        switch context {
        case .browserPage, .browserLink, .browserImage, .browserSelection: .browserFocused
        case .terminalSelection: .terminalFocused
        case .agentChat, .priorityRow: .agentPaneFocused
        // A right-clicked row is the explorer's even while another view has the keyboard.
        case .fileExplorerRow: .fileExplorerFocused
        default: []
        }
    }

    private func menuItems(_ entries: [ContextMenuEntry], target: ActionTargetRef?, context: ActionContext, implied: ActionContext,
                           arguments: [String: ActionValue], labels: [ActionID: String] = [:], machineID: String? = nil) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        for entry in entries {
            switch entry {
            case .separator:
                if let last = items.last, !last.isSeparatorItem { items.append(.separator()) }
            case .action(let id):
                var invocation = ActionInvocation(target: target, arguments: arguments)
                invocation.targetMachineID = machineID
                guard let descriptor = descriptor(for: id), isAvailable(descriptor.id, in: context),
                      !ActionTargetVisibility.isHidden(id, invocation: invocation, in: self), let item = makeMenuItem(for: id) else { continue }
                let payload = ActionMenuPayload(id: descriptor.id, target: target, arguments: arguments, implied: implied)
                payload.targetMachineID = machineID
                item.representedObject = payload
                item.image = Self.menuIcon(descriptor.symbol)
                // A menu-only short title (the palette keeps the action's title).
                if let label = labels[id] { item.title = label }
                // Built per click: names the target's change (Pin or Unpin, over the label), says why it is disabled.
                ActionTargetTitles.decorate(item, id: descriptor.id, invocation: invocation, in: self)
                items.append(item)
            case .submenu(let id, let children):
                let childItems = menuItems(children, target: target, context: context, implied: implied, arguments: arguments, labels: labels,
                                           machineID: machineID)
                guard !childItems.isEmpty, let title = labels[id] ?? title(for: id) else { continue }
                let item = NSMenuItem(title: title.droppingEllipsis, action: nil, keyEquivalent: "")
                item.image = descriptor(for: id).flatMap { Self.menuIcon($0.symbol) }
                let submenu = NSMenu(title: item.title)
                childItems.forEach(submenu.addItem)
                item.submenu = submenu
                items.append(item)
            case .folder(let folder, let children):
                let childItems = menuItems(children, target: target, context: context, implied: implied, arguments: arguments, labels: labels,
                                           machineID: machineID)
                guard childItems.contains(where: { !$0.isSeparatorItem }) else { continue }
                let item = NSMenuItem(title: folder.title, action: nil, keyEquivalent: "")
                item.image = Self.menuIcon(folder.symbol)
                let submenu = NSMenu(title: folder.title)
                childItems.forEach(submenu.addItem)
                item.submenu = submenu
                items.append(item)
            case .group(let group, let children):
                // The person's own submenu (Settings > Menus): their title, no icon.
                let childItems = menuItems(children, target: target, context: context, implied: implied, arguments: arguments, labels: labels,
                                           machineID: machineID)
                guard childItems.contains(where: { !$0.isSeparatorItem }) else { continue }
                let item = NSMenuItem(title: group.title, action: nil, keyEquivalent: "")
                let submenu = NSMenu(title: group.title)
                childItems.forEach(submenu.addItem)
                item.submenu = submenu
                items.append(item)
            case .choices(let id):
                guard let descriptor = descriptor(for: id), isAvailable(descriptor.id, in: context),
                      let item = makeChoicesItem(for: descriptor, target: target, in: context)
                else { continue }
                if let machineID { scope(item, toMachine: machineID) }
                item.image = Self.menuIcon(descriptor.symbol)
                if let label = labels[id] { item.title = label.droppingEllipsis }
                items.append(item)
            }
        }
        while items.last?.isSeparatorItem == true { items.removeLast() }
        return items
    }
}

extension ActionRegistry {
    /// Gives every run in `item` and its submenus the machine that owns their target.
    func scope(_ item: NSMenuItem, toMachine machineID: String) {
        (item.representedObject as? ActionMenuPayload)?.targetMachineID = machineID
        if let submenu = item.submenu { choiceCoordinators.object(forKey: submenu)?.machineID = machineID }
        item.submenu?.items.forEach { self.scope($0, toMachine: machineID) }
    }

    /// A right-click row's icon: its action's SF Symbol as a template, inked like the row's text.
    /// Nil for `ActionDescriptor`'s default symbol (`command`), so a row without its own icon shows none.
    static func menuIcon(_ symbol: String) -> NSImage? {
        // The menu font's size, as `NSImage.menuSymbol` (CmuxNextDesign) sizes every hand-built row's symbol.
        let configuration = NSImage.SymbolConfiguration(pointSize: NSFont.menuFont(ofSize: 0).pointSize, weight: .regular, scale: .medium)
        guard symbol != "command",
              let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
        else { return nil }
        image.isTemplate = true
        return image
    }
}

private extension String {
    /// A submenu row drops the title's ellipsis.
    var droppingEllipsis: String { hasSuffix("…") ? String(dropLast()) : self }
}
