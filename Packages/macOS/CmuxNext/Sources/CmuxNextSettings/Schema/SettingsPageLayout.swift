import Foundation

/// The Settings page's navigation (SETTINGS-PAGE-FIRST-PRINCIPLES P2, P4):
/// categories by user task, each a list of group cards. Defined once here and
/// exported as the schema's `page` (`SettingsSchemaExport`); the web Settings
/// page and the GPUI client render it from the export and copy nothing
/// (layer-ownership.md L5). A row's key, section and CLI stay as they are;
/// only where the page draws it is decided here. Every row the page shows has
/// exactly one card (`SettingsPageLayoutTests`).
public nonisolated struct SettingsPageLayout: Sendable {
    /// A part of a category that is not a schema row (host lists, the theme
    /// studio, file actions). Raw values are the export's card ids.
    public nonisolated enum Card: String, Sendable, Hashable, CaseIterable {
        case themeStudio, terminalInfo, ghosttyDiagnostics, computerUse, harnesses, spaces, browserProfiles
        case machines, accounts, agentHarnesses, advancedInfo, advancedActions, backdrops
    }

    /// A group card as the layout states it: the rows of a schema group
    /// (minus rows another card claims), plus rows claimed by key.
    public nonisolated struct GroupSpec: Sendable {
        /// A schema group key: its title, and every row of it no other card claims.
        public var group: String?
        /// Rows by key, moved here from their schema group; `title` names the card then.
        public var keys: [String] = []
        public var title: SettingText?
    }

    public nonisolated struct CategorySpec: Sendable {
        public var id: String
        public var title: SettingText
        public var symbol: String
        public var groups: [GroupSpec]
        /// Cards drawn before the groups, and after them.
        public var lead: [Card] = []
        public var trail: [Card] = []
        /// The sections whose registry buttons (cmux.settings.section.actions) show at the end.
        public var actions: [SettingsSection] = []
        /// The section ids (`cmux settings open --section`, old links) that open this category.
        public var aliases: [SettingsSection] = []
    }

    /// A resolved group card: its rows in display order.
    public nonisolated struct Group: Sendable, Hashable {
        public let key: String
        public let title: SettingText
        public let rows: [String]
    }

    public nonisolated struct Category: Sendable {
        public let spec: CategorySpec
        public let groups: [Group]
    }

    public static let defaultCategory = "general"

    public init() {}

    /// The categories with their cards resolved against `rows`: only rows the
    /// page shows, empty cards dropped, schema-group rows in schema order.
    public func categories(rows: [SettingDescriptor] = SettingsSchema.all) -> [Category] {
        let shown = rows.filter(\.isShownOnSettingsPage)
        let specs = Self.specs
        let claimed = Set(specs.flatMap { $0.groups.flatMap(\.keys) })
        let ids = Set(shown.map(\.id))
        return specs.map { spec in
            let groups = spec.groups.enumerated().compactMap { index, group -> Group? in
                let own = group.group.map { key in
                    shown.filter { $0.textKeys.group == key && !claimed.contains($0.id) }.map(\.id)
                } ?? []
                let moved = group.keys.filter(ids.contains)
                let rows = own + moved
                let title = group.title ?? group.group.flatMap { key in
                    shown.first { $0.textKeys.group == key }.map { SettingText(key: key, text: $0.group) }
                }
                guard !rows.isEmpty, let title else { return nil }
                return Group(key: group.group ?? "\(spec.id).\(index)", title: title, rows: rows)
            }
            return Category(spec: spec, groups: groups)
        }
    }

    private static func section(_ section: SettingsSection) -> SettingText {
        SettingText(key: section.titleKey, text: section.title)
    }

    private static func group(_ key: String) -> GroupSpec { GroupSpec(group: key) }

    static let specs: [CategorySpec] = [
        CategorySpec(
            id: "general", title: section(.general), symbol: "gearshape",
            groups: [
                group("settings.group.window"), group("settings.group.tabs"), group("settings.group.columns"),
                group("settings.group.history"), group("settings.group.quit"), group("settings.group.picker"),
                group("settings.group.tasks"), group("settings.group.diffViewer"), group("settings.group.updates"),
                group("settings.group.announcements"), group("settings.group.chats"),
            ],
            trail: [.spaces], actions: [.general, .rooms], aliases: [.general, .rooms]),
        CategorySpec(
            id: "theme", title: SettingsText.keyed("settings.category.theme", "Theme"), symbol: "paintpalette",
            // appearance.theme and appearance.appTheme are drawn by the theme
            // studio (search still shows them as rows).
            groups: [group("settings.group.appTheme")],
            lead: [.themeStudio]),
        CategorySpec(
            id: "appearance", title: section(.appearance), symbol: "paintbrush",
            groups: [
                group("settings.group.terminalFont"), group("settings.group.densityMotion"),
                group("settings.group.windowBackground"), group("settings.group.panes"), group("settings.group.focusRing"),
                group("settings.group.sidebar"), group("settings.group.workspaceRows"),
                group("settings.group.statusIndicator"), group("settings.group.surfaces"),
            ],
            actions: [.appearance], aliases: [.appearance]),
        CategorySpec(
            id: "terminal", title: section(.terminal), symbol: "terminal",
            groups: [
                GroupSpec(keys: ["newTerminal.opensWorkspace", "app.warnBeforeClosingTab"],
                          title: SettingsText.keyed("settings.pageGroup.terminalBehavior", "Behavior")),
            ],
            lead: [.terminalInfo], trail: [.ghosttyDiagnostics], actions: [.terminal], aliases: [.terminal]),
        CategorySpec(
            id: "agents", title: SettingsText.keyed("settings.category.agents", "Agents"), symbol: "sparkles",
            groups: [
                GroupSpec(group: "settings.group.agentChat", keys: ["app.warnBeforeClosingAgentSession"]),
                group("settings.group.computerUse"),
            ],
            // Harnesses lists every harness; Your Agents (BRING-YOUR-OWN-HARNESS) adds, checks and
            // removes the ones you added.
            trail: [.harnesses, .agentHarnesses, .computerUse]),
        // A core cmux feature: banners, sounds, the attention ring and the
        // feed for agents, terminal programs and `cmux notify`.
        CategorySpec(
            id: "notifications", title: section(.notifications), symbol: "bell",
            groups: [
                group("settings.group.banners"), group("settings.group.dismissal"), group("settings.group.attention"),
                group("settings.group.feedMirror"), group("settings.group.githubInbox"),
            ],
            actions: [.notifications], aliases: [.notifications]),
        CategorySpec(
            id: "browser", title: section(.browser), symbol: "globe",
            groups: [
                group("settings.group.engine"), group("settings.group.addressBar"), group("settings.group.bookmarks"),
                group("settings.group.links"), group("settings.group.memory"), group("settings.group.remote"),
            ],
            trail: [.browserProfiles], actions: [.browser], aliases: [.browser]),
        CategorySpec(
            id: "keyboard", title: section(.keyboard), symbol: "keyboard",
            groups: [
                group("settings.shortcuts.hintsGroup"),
                GroupSpec(keys: ["sidebar.numbering", "sidebar.cmd9", "sidebar.stepping", "sidebar.steppingWraps"],
                          title: SettingsText.keyed("settings.pageGroup.sidebarKeys", "Sidebar Navigation")),
                group("settings.group.palette"),
            ],
            actions: [.keyboard], aliases: [.keyboard]),
        CategorySpec(
            id: "privacy", title: SettingsText.keyed("settings.category.privacy", "Privacy and Security"),
            symbol: "hand.raised",
            groups: [
                GroupSpec(keys: ["history.terminalCommands", "home.attachments.keepLocation"],
                          title: SettingsText.keyed("settings.pageGroup.localData", "Data on This Mac")),
                GroupSpec(keys: ["browser.omnibar.remoteSuggestions", "announcements.fetch"],
                          title: SettingsText.keyed("settings.pageGroup.network", "Network Requests")),
            ],
            actions: [.home], aliases: [.home]),
        CategorySpec(
            id: "accounts", title: section(.accounts), symbol: "person.crop.circle", groups: [],
            lead: [.accounts, .machines], actions: [.accounts, .machines], aliases: [.accounts, .machines]),
        CategorySpec(
            id: "advanced", title: section(.advanced), symbol: "curlybraces", groups: [],
            lead: [.advancedInfo], trail: [.advancedActions], actions: [.advanced], aliases: [.advanced]),
        CategorySpec(
            id: "experimental", title: SettingsText.keyed("settings.category.experimental", "Experimental"),
            symbol: "flask",
            groups: [
                GroupSpec(group: "settings.group.labs", keys: ["appearance.experimentalControls"]),
                group("settings.group.appearanceTuning"),
            ],
            trail: [.backdrops]),
    ]
}
