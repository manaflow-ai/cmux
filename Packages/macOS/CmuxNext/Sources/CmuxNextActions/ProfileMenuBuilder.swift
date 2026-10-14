public import AppKit

/// The profile the menu's "Profiles" section shows: today only the
/// current one (real profiles are a later lane).
public nonisolated struct ProfileMenuProfile: Sendable, Hashable {
    public var name: String

    public init(name: String) {
        self.name = name
    }
}

/// Builds the sidebar profile menu (`ProfileMenuSpec`): native rows, each a
/// registry item (its effective shortcut from the key bindings, its run
/// through `ActionMenuTarget`), SF Symbols on the top-level rows. Rows whose
/// action this build does not register are left out, and so is a submenu
/// left with no row.
@MainActor public struct ProfileMenuBuilder {
    public let registry: ActionRegistry

    public init(registry: ActionRegistry) {
        self.registry = registry
    }

    public func make(profile: ProfileMenuProfile, spec: ProfileMenuSpec = ProfileMenuSpec()) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = true
        menu.addItem(.sectionHeader(title: spec.sectionTitle))
        menu.addItem(profileRow(profile, actions: spec.profileActions))
        menu.addItem(.separator())
        for submenu in spec.submenus {
            let rows = submenu.actions.compactMap(boundMenuItem)
            guard !rows.isEmpty else { continue }
            let item = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
            item.image = Self.symbol(submenu.symbol, label: submenu.title)
            item.identifier = NSUserInterfaceItemIdentifier("profileMenu.\(submenu.key)")
            let sub = NSMenu(title: submenu.title)
            sub.autoenablesItems = true
            rows.forEach(sub.addItem)
            item.submenu = sub
            menu.addItem(item)
        }
        if let settings = row(spec.settings) { menu.addItem(settings) }
        let creation = spec.creation.compactMap(row)
        if !creation.isEmpty {
            menu.addItem(.separator())
            creation.forEach(menu.addItem)
        }
        return menu
    }

    /// The current profile and a "…" submenu with its options. No checkmark
    /// and no avatar: a checked row reserves a state column, and an image
    /// reserves an image column, for every row of the menu, which pushed
    /// them all right of the menu's inset (the sidebar control the menu
    /// opens from shows the avatar). With one profile a checkmark meant
    /// nothing.
    private func profileRow(_ profile: ProfileMenuProfile, actions: [ActionID]) -> NSMenuItem {
        let item = NSMenuItem(title: profile.name, action: nil, keyEquivalent: "")
        item.identifier = NSUserInterfaceItemIdentifier("profileMenu.currentProfile")
        let options = actions.compactMap(boundMenuItem)
        if !options.isEmpty {
            let sub = NSMenu(title: profile.name)
            sub.autoenablesItems = true
            options.forEach(sub.addItem)
            item.submenu = sub
        }
        return item
    }

    private func row(_ row: ProfileMenuSpec.Row) -> NSMenuItem? {
        guard let item = boundMenuItem(row.action) else { return nil }
        if let title = row.title { item.title = title }
        item.image = Self.symbol(row.symbol, label: item.title)
        return item
    }

    /// `makeMenuItem(for:)` for an action this build registers.
    private func boundMenuItem(_ id: ActionID) -> NSMenuItem? {
        guard registry.action(for: id) != nil else { return nil }
        return registry.makeMenuItem(for: id)
    }

    private static func symbol(_ name: String, label: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: label)
    }
}
