public import AppKit

/// Chrome's profile menu for a browser tab (https://github.com/manaflow-ai/cmux/issues/42438), shown by the omnibar's
/// profile avatar and the toolbar's profile button: the tab's profile as the header; Other
/// Profiles, one row each that moves the tab into it in one click (`browserProfile.moveTab`; with
/// Option, `browserProfile.setWorkspaceDefault` for the tab's workspace); Add, Guest (an incognito
/// window) and Manage (Settings > Browser Profiles); then the profile's own actions (the
/// `.browserProfile` menu: New Tab, Window and Workspace with it, Rename, Appearance, Clear
/// Browsing Data, Delete). Every row is a registry item that runs a catalog action.
@MainActor public struct BrowserProfileSwitcherMenuBuilder {
    /// One browser profile as the menu shows it.
    public struct Profile {
        public var id: String
        public var name: String
        /// Its round avatar (`ProfileBadgeView.image`), drawn at `avatarSide`.
        public var avatar: (_ side: CGFloat) -> NSImage?

        public init(id: String, name: String, avatar: @escaping (_ side: CGFloat) -> NSImage?) {
            self.id = id
            self.name = name
            self.avatar = avatar
        }
    }

    public let registry: ActionRegistry

    public init(registry: ActionRegistry) {
        self.registry = registry
    }

    /// `tab` is the browser tab the menu acts on, `workspace` its workspace (nil: no Option
    /// row). `others` empty (one profile, or an incognito tab that keeps its window's profile)
    /// leaves out Other Profiles. `customize` ends the menu with Customize Menu….
    public func make(current: Profile, others: [Profile], tab: ActionTargetRef, workspace: ActionTargetRef?,
                     customize: Bool = true) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = true
        menu.addItem(header(current))
        if !others.isEmpty {
            menu.addItem(.separator())
            menu.addItem(.sectionHeader(title: Self.text("menu.browserProfile.switcher.others", "Other Profiles")))
            others.forEach { switchRows($0, tab: tab, workspace: workspace).forEach(menu.addItem) }
        }
        menu.addItem(.separator())
        let rows: [(ActionID, String, String, [String: ActionValue])] = [
            ("browserProfile.new", Self.text("menu.browserProfile.switcher.add", "Add Browser Profile…"), "plus", [:]),
            ("newIncognitoWindow", Self.text("menu.browserProfile.switcher.guest", "Open Guest Window"), "person.crop.circle", [:]),
            ("openSettings", Self.text("menu.browserProfile.switcher.manage", "Manage Browser Profiles…"), "gearshape",
             ["setting": .string("card.browserProfiles")]),
        ]
        for (id, title, symbol, arguments) in rows {
            guard let row = registry.makeContextMenuItem(for: id, in: .browserProfile, arguments: arguments, title: title) else { continue }
            row.image = Self.symbol(symbol, label: title)
            menu.addItem(row)
        }
        menu.addItem(.separator())
        // The profile's own actions, which open in the tab's pane (its `tab` argument), not the
        // focused one. Add above stands for New Browser Profile.
        let own = registry.makeContextMenu(for: .browserProfile, target: ActionTargetRef(kind: .browserProfile, id: current.id),
                                           entries: registry.contextMenuEntries(for: .browserProfile, removing: ["browserProfile.new"]),
                                           arguments: ["tab": .target(tab)], customize: customize)
        for item in own.items {
            own.removeItem(item)
            menu.addItem(item)
        }
        return menu
    }

    /// The row that moves `tab` into `profile`, and its Option alternate for the workspace.
    private func switchRows(_ profile: Profile, tab: ActionTargetRef, workspace: ActionTargetRef?) -> [NSMenuItem] {
        let avatar = profile.avatar(Self.rowAvatarSide)
        let chosen: [String: ActionValue] = ["browserProfile": .string(profile.id)]
        var rows: [NSMenuItem] = []
        if let row = registry.makeContextMenuItem(for: "browserProfile.moveTab", in: .browserProfile, target: tab,
                                                  arguments: chosen, title: profile.name) {
            row.image = avatar
            row.identifier = NSUserInterfaceItemIdentifier("browserProfile.switch.\(profile.id)")
            rows.append(row)
        }
        let title = String(format: Self.text("menu.browserProfile.switcher.useForWorkspace", "Use “%@” for This Workspace"), profile.name)
        if let workspace, !rows.isEmpty,
           let row = registry.makeContextMenuItem(for: "browserProfile.setWorkspaceDefault", in: .browserProfile,
                                                  arguments: chosen.merging(["workspace": .target(workspace)]) { mine, _ in mine }, title: title) {
            row.image = avatar
            row.isAlternate = true
            row.keyEquivalentModifierMask = .option
            rows.append(row)
        }
        return rows
    }

    /// The tab's profile: its avatar, its name and "Current profile", as Chrome's menu opens.
    private func header(_ profile: Profile) -> NSMenuItem {
        let caption = Self.text("menu.browserProfile.switcher.current", "Current profile")
        let item = NSMenuItem(title: profile.name, action: nil, keyEquivalent: "")
        item.identifier = NSUserInterfaceItemIdentifier("browserProfile.switcher.current")
        let menuFont = NSFont.menuFont(ofSize: 0)
        let name = NSTextField(labelWithString: profile.name)
        name.font = NSFontManager.shared.convert(menuFont, toHaveTrait: .boldFontMask)
        name.lineBreakMode = .byTruncatingTail
        let detail = NSTextField(labelWithString: caption)
        detail.font = NSFont.menuFont(ofSize: NSFont.smallSystemFontSize)
        detail.textColor = .secondaryLabelColor
        let text = NSStackView(views: [name, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        let side = menuFont.pointSize * 2 + 4
        let avatar = NSImageView(image: profile.avatar(side) ?? NSImage())
        let row = NSStackView(views: [avatar, text])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 6, left: 14, bottom: 6, right: 14)
        row.setAccessibilityElement(true)
        row.setAccessibilityRole(.staticText)
        row.setAccessibilityLabel("\(profile.name), \(caption)")
        NSLayoutConstraint.activate([
            avatar.widthAnchor.constraint(equalToConstant: side),
            avatar.heightAnchor.constraint(equalToConstant: side),
            row.widthAnchor.constraint(greaterThanOrEqualToConstant: 220),
        ])
        row.frame.size = row.fittingSize
        item.view = row
        return item
    }

    /// The other profiles' avatars: the menu font's height, as a row's image column.
    static var rowAvatarSide: CGFloat { NSFont.menuFont(ofSize: 0).pointSize + 5 }

    /// A template at the menu font's size, as the sidebar profile menu's rows (`ProfileMenuBuilder`).
    private static func symbol(_ name: String, label: String) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: NSFont.menuFont(ofSize: 0).pointSize, weight: .regular, scale: .medium)
        let image = NSImage(systemSymbolName: name, accessibilityDescription: label)?.withSymbolConfiguration(configuration)
        image?.isTemplate = true
        return image
    }

    private static func text(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, table: "ProfileActions", bundle: .module)
    }
}
