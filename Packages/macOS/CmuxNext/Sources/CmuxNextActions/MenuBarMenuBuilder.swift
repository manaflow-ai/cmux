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
    public func fill(_ menu: NSMenu, state: MenuBarMenuState, avatar: NSImage? = nil) {
        menu.removeAllItems()
        menu.autoenablesItems = true
        for item in spec.items(for: state, isBound: { registry.action(for: $0) != nil }) {
            switch item {
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
            }
        }
    }

    /// Open cmux shows Show/Hide All Windows' system-wide key, as Raycast's Open Raycast shows ⌥Space.
    private func showGlobalKey(on row: NSMenuItem) {
        guard let shortcut = registry.effectiveShortcut(for: "showHideAllWindows") else { return }
        row.keyEquivalent = shortcut.key
        row.keyEquivalentModifierMask = shortcut.modifiers
    }

    private static func symbol(_ name: String, label: String) -> NSImage? {
        // A template at the menu font's size, as the profile menu's rows (`ProfileMenuBuilder`).
        let configuration = NSImage.SymbolConfiguration(pointSize: NSFont.menuFont(ofSize: 0).pointSize, weight: .regular, scale: .medium)
        let image = NSImage(systemSymbolName: name, accessibilityDescription: label)?.withSymbolConfiguration(configuration)
        image?.isTemplate = true
        return image
    }
}
