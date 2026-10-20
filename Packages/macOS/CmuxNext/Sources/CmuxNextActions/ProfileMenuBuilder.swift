public import AppKit

/// The profile the menu's first row shows: today only the current one
/// (real profiles are a later lane).
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

    /// `avatar` is drawn in the current-profile row's image column. `chiefPetShown` (the
    /// `home.chiefPetEnabled` that applies now) adds Show Chief or Hide Chief above Settings; nil
    /// leaves the row out.
    public func make(profile: ProfileMenuProfile, avatar: NSImage? = nil, chiefPetShown: Bool? = nil,
                     spec: ProfileMenuSpec = ProfileMenuSpec()) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = true
        menu.addItem(profileRow(profile, avatar: avatar, actions: spec.profileActions))
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
        if let chiefPetShown, let chief = chiefPetRow(shown: chiefPetShown) { menu.addItem(chief) }
        if let settings = row(spec.settings) { menu.addItem(settings) }
        let creation = spec.creation.compactMap(row)
        if !creation.isEmpty {
            menu.addItem(.separator())
            creation.forEach(menu.addItem)
        }
        return menu
    }

    /// The current profile, its avatar and a submenu with its options. A
    /// checkmark and section header are unnecessary with one current profile.
    private func profileRow(_ profile: ProfileMenuProfile, avatar: NSImage?, actions: [ActionID]) -> NSMenuItem {
        let item = NSMenuItem(title: profile.name, action: nil, keyEquivalent: "")
        item.image = avatar
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

    /// Show Chief / Hide Chief (Leo 2026-10-20, as Codex's profile menu toggles its floating
    /// window): flips `home.chiefPetEnabled` to the other value through the one setting path,
    /// `palette.toggleSetting`, as the palette and `cmux settings toggle-setting` do.
    private func chiefPetRow(shown: Bool) -> NSMenuItem? {
        let toggle: ActionID = "palette.toggleSetting"
        guard let item = boundMenuItem(toggle) else { return nil }
        item.title = shown ? ProfileMenuSpec.text("menu.profile.hideChief", "Hide Chief")
            : ProfileMenuSpec.text("menu.profile.showChief", "Show Chief")
        item.keyEquivalent = ""
        item.keyEquivalentModifierMask = []
        item.image = Self.symbol(shown ? "eye.slash" : "eye", label: item.title)
        item.identifier = NSUserInterfaceItemIdentifier("profileMenu.chiefPet")
        item.representedObject = ActionMenuPayload(id: toggle, target: nil,
                                                   arguments: ["setting": .string(ProfileMenuSpec.chiefPetSetting), "on": .bool(!shown)])
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
