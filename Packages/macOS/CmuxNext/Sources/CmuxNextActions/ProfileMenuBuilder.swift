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

    /// The menu, laid out as the Codex app's account menu (``ProfileMenuSpec``): the current profile's row (its
    /// `avatar`, a chevron to its options and Accounts…), New Workspace and New Window with their shortcuts, then
    /// Extensions ›, History ›, Cloud, Settings… and Check for Updates…, then Help. ``addAccountRows(to:who:avatar:)``
    /// swaps the profile's row for the signed-in person's and ends the menu with Sign Out or Sign In.
    public func make(profile: ProfileMenuProfile, avatar: NSImage? = nil, spec: ProfileMenuSpec = ProfileMenuSpec()) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = true
        menu.addItem(profileRow(profile, avatar: avatar, actions: spec.profileActions, accounts: spec.accounts))
        let sections: [[NSMenuItem]] = [
            spec.creation.compactMap(row),
            spec.submenus.compactMap(submenuRow) + [spec.cloud, spec.settings, spec.updates].compactMap(row),
            helpRow(spec.help).map { [$0] } ?? [],
        ]
        for section in sections where !section.isEmpty {
            menu.addItem(.separator())
            section.forEach(menu.addItem)
        }
        Self.keepOneTextColumn(menu)
        return menu
    }

    /// The account rows. Signed in (`who` is the name, then the email), the profile's row becomes who it is: their
    /// picture or initials, the name with the email under it, and a chevron to every team the account may work in
    /// (the active one checked) and Accounts…, as the Codex app's account row opens its workspaces. Sign Out ends
    /// the menu. Signed out (`who` nil), Sign In ends it and the profile's row stays.
    ///
    /// Who it is is a row that opens a submenu, never a greyed header that reads as a state (Leo, 2026-11-09, of the
    /// greyed email: "but does this not mean it's already connected?"). The teams are Switch Active Team's own values
    /// (`openTeamPicker`'s `cloudTeams`), each with its icon (a person for the person's own team, people for a shared
    /// one), the active one checked, so the team in effect reads as a choice (Leo, 2026-11-09).
    public func addAccountRows(to menu: NSMenu, who: [String]?, avatar: NSImage? = nil, spec: ProfileMenuSpec = ProfileMenuSpec()) {
        defer { Self.keepOneTextColumn(menu) }
        let auth: ActionID = who == nil ? "palette.auth.signIn" : "palette.auth.signOut"
        if let item = registry.makeMenuItem(for: auth) {
            item.image = registry.descriptor(for: auth).flatMap { Self.symbol($0.symbol, label: item.title) ?? registry.rowIcon($0.symbol) }
            // In Help's section, as the Codex menu's Log out; else a section of its own.
            if let last = menu.items.last, last.identifier?.rawValue != "profileMenu.help" { menu.addItem(.separator()) }
            menu.addItem(item)
        }
        guard let who, let name = who.first else { return }
        // The profile's own options move into who it is's submenu, under the teams: one account row.
        var options: [NSMenuItem] = []
        if let first = menu.items.first, first.identifier?.rawValue == "profileMenu.currentProfile" {
            menu.removeItem(first)
            options = Self.takeRows(of: first.submenu).filter { $0.identifier?.rawValue != "cmux.action.\(spec.accounts.action.rawValue)" }
        }
        let person = personRow(name: name, email: who.count > 1 ? who[1] : nil, avatar: avatar, options: options, accounts: spec.accounts)
        menu.insertItem(person, at: 0)
    }

    /// Who is signed in: one row, the email as its second line where the system draws one (macOS 14.4), opening the
    /// teams, the browser profile's `options` and Accounts…, a section each.
    private func personRow(name: String, email: String?, avatar: NSImage?, options: [NSMenuItem],
                           accounts: ProfileMenuSpec.Row) -> NSMenuItem {
        let person = NSMenuItem(title: name, action: nil, keyEquivalent: "")
        person.image = avatar
        person.identifier = NSUserInterfaceItemIdentifier("profileMenu.person")
        if #available(macOS 14.4, *), let email { person.subtitle = email }
        var rows: [NSMenuItem] = []
        for section in [teamRows(), options.filter { !$0.isSeparatorItem }, row(accounts).map { [$0] } ?? []] where !section.isEmpty {
            if !rows.isEmpty { rows.append(.separator()) }
            rows += section
        }
        if !rows.isEmpty {
            let sub = NSMenu(title: name)
            sub.autoenablesItems = true
            rows.forEach(sub.addItem)
            Self.keepOneTextColumn(sub)
            person.submenu = sub
        }
        return person
    }

    /// Every team the account may work in, as Switch Active Team lists them, the active one
    /// checked (`choiceState`); none while the action is unbound or unavailable (signed out). No second line: every
    /// row of the submenu is a team, and the icon tells the person's own from a shared one.
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
            return item
        }
    }

    /// The current profile, its avatar and a submenu with its options and Accounts…. A
    /// checkmark and section header are unnecessary with one current profile.
    private func profileRow(_ profile: ProfileMenuProfile, avatar: NSImage?, actions: [ActionID],
                            accounts: ProfileMenuSpec.Row) -> NSMenuItem {
        let item = NSMenuItem(title: profile.name, action: nil, keyEquivalent: "")
        item.image = avatar
        item.identifier = NSUserInterfaceItemIdentifier("profileMenu.currentProfile")
        var rows = actions.compactMap(boundMenuItem)
        if let accounts = row(accounts) {
            if !rows.isEmpty { rows.append(.separator()) }
            rows.append(accounts)
        }
        if !rows.isEmpty {
            let sub = NSMenu(title: profile.name)
            sub.autoenablesItems = true
            rows.forEach(sub.addItem)
            Self.keepOneTextColumn(sub)
            item.submenu = sub
        }
        return item
    }

    /// `menu`'s rows, removed from it so another menu can hold them (an item belongs to one menu).
    private static func takeRows(of menu: NSMenu?) -> [NSMenuItem] {
        guard let menu else { return [] }
        let items = menu.items
        menu.removeAllItems()
        return items
    }

    /// Help ›: the Help menu's rows this build binds; nil with none.
    private func helpRow(_ actions: [ActionID]) -> NSMenuItem? {
        let rows = actions.compactMap(boundMenuItem)
        guard !rows.isEmpty else { return nil }
        let title = ProfileMenuSpec.helpTitle
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.image = Self.symbol(ProfileMenuSpec.helpSymbol, label: title)
        item.identifier = NSUserInterfaceItemIdentifier("profileMenu.help")
        let sub = NSMenu(title: title)
        sub.autoenablesItems = true
        rows.forEach(sub.addItem)
        item.submenu = sub
        return item
    }

    /// One "Extensions ›" row: the submenu's actions this build binds; nil with none.
    private func submenuRow(_ submenu: ProfileMenuSpec.Submenu) -> NSMenuItem? {
        let rows = submenu.actions.compactMap(boundMenuItem)
        guard !rows.isEmpty else { return nil }
        let item = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
        item.image = Self.symbol(submenu.symbol, label: submenu.title)
        let sub = NSMenu(title: submenu.title)
        sub.autoenablesItems = true
        rows.forEach(sub.addItem)
        item.submenu = sub
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
        // A template at the menu font's size, as every right-click row's symbol (`ActionRegistry.menuIcon`). The glass
        // menu draws it in the secondary ink, the Codex account menu's quiet icons.
        let configuration = NSImage.SymbolConfiguration(pointSize: NSFont.menuFont(ofSize: 0).pointSize, weight: .regular, scale: .medium)
        let image = NSImage(systemSymbolName: name, accessibilityDescription: label)?.withSymbolConfiguration(configuration)
        image?.isTemplate = true
        return image
    }
}
