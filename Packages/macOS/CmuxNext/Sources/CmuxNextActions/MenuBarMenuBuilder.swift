public import AppKit

/// Builds the menu bar menu (``MenuBarMenuSpec``): native rows, each a registry item (its
/// effective shortcut from the key bindings, its run through the registry's menu target), with
/// SF Symbols. Info lines are disabled rows; the first account line shows `avatar`.
///
/// ```swift
/// let menu = NSMenu()
/// MenuBarMenuBuilder(registry: registry).fill(menu, state: MenuBarMenuState(agentsWorking: 2))
/// ```
@MainActor public struct MenuBarMenuBuilder {
    public let registry: ActionRegistry
    public let spec: MenuBarMenuSpec

    /// - Parameters:
    ///   - registry: Runs every row and gives its title and shortcut.
    ///   - spec: The rows; the default is cmux's menu.
    public init(registry: ActionRegistry, spec: MenuBarMenuSpec = MenuBarMenuSpec()) {
        self.registry = registry
        self.spec = spec
    }

    /// Replaces `menu`'s rows with the rows for `state` (called as the menu opens).
    ///
    /// - Parameters:
    ///   - menu: The status item's menu.
    ///   - state: What the menu shows besides its fixed rows.
    ///   - avatar: The signed-in account's picture, nil for none.
    ///   - commands: Runs the chat and Computer Use rows; nil leaves them disabled.
    ///   - chatImage: A chat row's harness mark (the sidebar's), nil for none.
    public func fill(_ menu: NSMenu, state: MenuBarMenuState, avatar: NSImage? = nil, commands: MenuBarCommandTarget? = nil,
                     chatImage: (MenuBarMenuState.Chat) -> NSImage? = { _ in nil }) {
        menu.removeAllItems()
        menu.autoenablesItems = true
        add(spec.items(for: state, isBound: { registry.action(for: $0) != nil }), to: menu, state: state, avatar: avatar,
            commands: commands, chatImage: chatImage)
    }

    private func add(_ items: [MenuBarMenuSpec.Item], to menu: NSMenu, state: MenuBarMenuState, avatar: NSImage?,
                     commands: MenuBarCommandTarget?, chatImage: (MenuBarMenuState.Chat) -> NSImage?) {
        for item in items {
            switch item {
            case .header(let title):
                menu.addItem(.sectionHeader(title: title))
            case .chat(let chat):
                let row = commands?.item(.openChat(chat.id), title: chat.title)
                    ?? NSMenuItem(title: chat.title, action: nil, keyEquivalent: "")
                row.image = chatImage(chat)
                row.toolTip = chat.title // tooltip-native-allow: an NSMenuItem (commands.item returns one), native to menus
                menu.addItem(row)
            case .command(let command, let title, let symbol):
                let row = commands?.item(command, title: title) ?? NSMenuItem(title: title, action: nil, keyEquivalent: "")
                row.image = Self.symbol(symbol, label: title)
                menu.addItem(row)
            case .computerUse(let app, let bundleID, let items):
                let row = NSMenuItem(title: MenuBarMenuSpec.text("menu.menuBar.computerUse", "Computer Use"), action: nil, keyEquivalent: "")
                row.identifier = Self.computerUseRow
                fillComputerUse(row, app: app, bundleID: bundleID, items: items, state: state, commands: commands)
                menu.addItem(row)
            case .separator:
                menu.addItem(.separator())
            case .info(let text, let symbol, let isAvatar):
                let row = NSMenuItem(title: text, action: nil, keyEquivalent: "")
                row.isEnabled = false
                row.image = isAvatar ? avatar : symbol.flatMap { Self.symbol($0, label: text) }
                menu.addItem(row)
            case .action(let id, let title, let symbol):
                guard let row = registry.makeMenuItem(for: id) else { continue }
                if let title { row.title = title }
                row.image = Self.symbol(symbol, label: row.title)
                if id == "showMainWindow", state.showsGlobalKey { showGlobalKey(on: row) }
                menu.addItem(row)
            case .setting(let title, let key, let symbol):
                guard let row = registry.makeMenuItem(for: "openSettings") else { continue }
                row.title = title
                row.image = Self.symbol(symbol, label: title)
                row.representedObject = ActionMenuPayload(id: "openSettings", target: nil, arguments: ["setting": .string(key)])
                row.keyEquivalent = ""
                // Its own id: Settings… keeps `cmux.action.openSettings` for accessibility clients.
                row.identifier = NSUserInterfaceItemIdentifier("cmux.setting.\(key)")
                menu.addItem(row)
            }
        }
    }

    /// Open cmux shows Show/Hide All Windows' system-wide key, as Raycast's Open Raycast shows ⌥Space.
    private func showGlobalKey(on row: NSMenuItem) {
        guard let shortcut = registry.effectiveShortcut(for: "showHideAllWindows") else { return }
        row.keyEquivalent = shortcut.key
        row.keyEquivalentModifierMask = shortcut.modifiers
    }

    /// The Computer Use row's identifier, so an answer that comes in while the menu is open
    /// rewrites that row alone (``updateComputerUse(in:_:commands:)``).
    static let computerUseRow = NSUserInterfaceItemIdentifier("cmux.menuBar.computerUse")

    /// Rewrites the open menu's Computer Use row for `computerUse` (the CUA host's answer came
    /// after the menu opened): its icon, the driven app and its submenu change in place.
    public func updateComputerUse(in menu: NSMenu, _ computerUse: MenuBarMenuState.ComputerUse, commands: MenuBarCommandTarget?) {
        guard let row = menu.items.first(where: { $0.identifier == Self.computerUseRow }) else { return }
        let state = MenuBarMenuState(computerUse: computerUse)
        for case .computerUse(let app, let bundleID, let items) in spec.items(for: state, isBound: { registry.action(for: $0) != nil }) {
            fillComputerUse(row, app: app, bundleID: bundleID, items: items, state: state, commands: commands)
        }
    }

    private func fillComputerUse(_ row: NSMenuItem, app: String?, bundleID: String?, items: [MenuBarMenuSpec.Item],
                                 state: MenuBarMenuState, commands: MenuBarCommandTarget?) {
        row.image = Self.appIcon(bundleID) ?? Self.symbol("cursorarrow.rays", label: row.title)
        row.badge = app.map { NSMenuItemBadge(string: $0) }
        let submenu = NSMenu(title: row.title)
        submenu.autoenablesItems = true
        add(items, to: submenu, state: state, avatar: nil, commands: commands, chatImage: { _ in nil })
        row.submenu = submenu
    }

    /// The driven app's icon at menu row size, nil when no app with `bundleID` is installed.
    private static func appIcon(_ bundleID: String?) -> NSImage? {
        guard let bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        let side = NSFont.menuFont(ofSize: 0).pointSize + 3
        icon.size = NSSize(width: side, height: side)
        return icon
    }

    private static func symbol(_ name: String, label: String) -> NSImage? {
        // A template at the menu font's size, as the profile menu's rows (`ProfileMenuBuilder`).
        let configuration = NSImage.SymbolConfiguration(pointSize: NSFont.menuFont(ofSize: 0).pointSize, weight: .regular, scale: .medium)
        let image = NSImage(systemSymbolName: name, accessibilityDescription: label)?.withSymbolConfiguration(configuration)
        image?.isTemplate = true
        return image
    }
}

/// Runs the menu bar's per-session rows (``MenuBarMenuSpec/Command``): a chat to open, a Computer
/// Use session to take over or hand back. The menu's owner keeps it (a row's target is weak).
@MainActor public final class MenuBarCommandTarget: NSObject {
    private let run: @MainActor (MenuBarMenuSpec.Command) -> Void

    public init(run: @escaping @MainActor (MenuBarMenuSpec.Command) -> Void) {
        self.run = run
    }

    func item(_ command: MenuBarMenuSpec.Command, title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(runCommand(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = command
        return item
    }

    @objc private func runCommand(_ sender: NSMenuItem) {
        guard let command = sender.representedObject as? MenuBarMenuSpec.Command else { return }
        run(command)
    }
}
