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
    /// leaves the row out. Personalization… follows it (Leo 2026-11-07: the profile menu's fast
    /// path to the look of the app).
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
        if let personalization = row(spec.personalization) { menu.addItem(personalization) }
        if let settings = row(spec.settings) { menu.addItem(settings) }
        if let updates = row(spec.updates) { menu.addItem(updates) }
        spec.account.compactMap(row).forEach(menu.addItem)
        let creation = spec.creation.compactMap(row)
        if !creation.isEmpty {
            menu.addItem(.separator())
            creation.forEach(menu.addItem)
        }
        Self.keepOneTextColumn(menu)
        return menu
    }

    /// The account rows: signed in (`who` is the name, then the email), who it is, then every team
    /// the account may work in, and Sign Out at the end; signed out (`who` nil), Sign In at the end.
    ///
    /// Who it is is a normal row (its picture or initials, the name with the email under it) that
    /// opens Accounts…, never a greyed header that reads as a state (Leo, 2026-11-09, of the greyed
    /// email: "but does this not mean it's already connected?"). The teams are Switch Active Team's
    /// own values (`openTeamPicker`'s `cloudTeams`), one selectable row each with its icon (a person
    /// for the person's own team, people for a shared one) and second line, the active one checked,
    /// so the team in effect reads as a choice, not as a highlighted row (Leo, 2026-11-09, of the
    /// lone team row: "i guess is team? it's kinda hard to realize tho").
    public func addAccountRows(to menu: NSMenu, who: [String]?, avatar: NSImage? = nil) {
        defer { Self.keepOneTextColumn(menu) }
        let auth: ActionID = who == nil ? "palette.auth.signIn" : "palette.auth.signOut"
        if let item = registry.makeMenuItem(for: auth) {
            item.image = registry.descriptor(for: auth).flatMap { registry.rowIcon($0.symbol) }
            menu.addItem(.separator())
            menu.addItem(item)
        }
        guard let who, let name = who.first else { return }
        var rows = personRows(name: name, email: who.count > 1 ? who[1] : nil, avatar: avatar)
        let teams = teamRows()
        if !teams.isEmpty {
            rows.append(.separator())
            rows += teams
        }
        rows.append(.separator())
        for row in rows.reversed() { menu.insertItem(row, at: 0) }
    }

    /// Who is signed in: one row, the email as its second line where the system draws one (macOS
    /// 14.4), else on a row of its own. Both open Accounts… when the build binds it.
    private func personRows(name: String, email: String?, avatar: NSImage?) -> [NSMenuItem] {
        let accounts: ActionID = "accounts.show"
        func row(_ title: String) -> NSMenuItem {
            guard let item = boundMenuItem(accounts) else {
                let header = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                header.isEnabled = false
                return header
            }
            item.title = title
            item.keyEquivalent = ""
            item.keyEquivalentModifierMask = []
            return item
        }
        let person = row(name)
        person.image = avatar
        person.identifier = NSUserInterfaceItemIdentifier("profileMenu.person")
        guard let email else { return [person] }
        if #available(macOS 14.4, *) {
            person.subtitle = email
            return [person]
        }
        let line = row(email)
        line.identifier = NSUserInterfaceItemIdentifier("profileMenu.personEmail")
        return [person, line]
    }

    /// Every team the account may work in, as Switch Active Team lists them, the active one
    /// checked (`choiceState`); none while the action is unbound or unavailable (signed out).
    func teamRows() -> [NSMenuItem] {
        let action: ActionID = "openTeamPicker"
        guard registry.action(for: action) != nil, registry.unavailableReason(for: action) == nil else { return [] }
        let teams = registry.argumentSuggestions?(ActionSuggestions.cloudTeams) ?? []
        let active = registry.choiceState?(action, nil)
        return teams.compactMap { team in
            guard let item = registry.makeMenuItem(for: action) else { return nil }
            item.title = team.title
            item.keyEquivalent = ""
            item.keyEquivalentModifierMask = []
            item.image = Self.symbol(team.symbol ?? "person.2", label: team.title)
            item.state = team.value == active ? .on : .off
            item.identifier = NSUserInterfaceItemIdentifier("profileMenu.team")
            item.representedObject = ActionMenuPayload(id: action, target: nil, arguments: ["team": .string(team.value)])
            if #available(macOS 14.4, *) { item.subtitle = team.subtitle }
            return item
        }
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

    /// One text column (design/grid.md 5.3: "a row without an icon still starts its text on
    /// `text`"). AppKit starts a row's title after that row's own image, so in a menu where some
    /// rows have an icon, a row without one (the account's name and email, Sign Out, a profile
    /// with no avatar) starts its text an icon's width left of the others. Such a row gets an
    /// empty image the size of the grid's icon box: every row's text on one column, and the
    /// header lines read as the rows' labels, not as a column of their own.
    static func keepOneTextColumn(_ menu: NSMenu) {
        let rows = menu.items.filter { !$0.isSeparatorItem && $0.view == nil }
        guard rows.contains(where: { $0.image != nil }) else { return }
        for row in rows where row.image == nil { row.image = emptyIcon() }
    }

    /// An empty image in the grid's icon box (`MenuMetrics.iconSize`, kept in step by
    /// `ProfileMenuColumnTests`), so `themeRows` leaves it as it is.
    static func emptyIcon() -> NSImage {
        let image = NSImage(size: NSSize(width: emptyIconSide, height: emptyIconSide))
        image.isTemplate = true
        return image
    }

    /// `MenuMetrics.iconSize` (CmuxNextDesign, which this module does not import).
    static let emptyIconSide: CGFloat = 14

    /// `makeMenuItem(for:)` for an action this build registers.
    private func boundMenuItem(_ id: ActionID) -> NSMenuItem? {
        guard registry.action(for: id) != nil else { return nil }
        return registry.makeMenuItem(for: id)
    }

    private static func symbol(_ name: String, label: String) -> NSImage? {
        // A template at the menu font's size, as every right-click row's symbol (`ActionRegistry.menuIcon`).
        let configuration = NSImage.SymbolConfiguration(pointSize: NSFont.menuFont(ofSize: 0).pointSize, weight: .regular, scale: .medium)
        let image = NSImage(systemSymbolName: name, accessibilityDescription: label)?.withSymbolConfiguration(configuration)
        image?.isTemplate = true
        return image
    }
}
