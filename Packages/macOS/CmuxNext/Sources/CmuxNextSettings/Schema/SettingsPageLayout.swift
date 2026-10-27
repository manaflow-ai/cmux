import Foundation

/// The Settings page's navigation (SETTINGS-PAGE-FIRST-PRINCIPLES P2, P4):
/// categories by user task, each a list of group cards. Defined once here and
/// exported as the schema's `page` (`SettingsSchemaExport`); the web Settings
/// page and the GPUI client render it from the export and copy nothing
/// (layer-ownership.md L5). A row's key, section and CLI stay as they are;
/// only where the page draws it is decided here. Every row the page shows has
/// exactly one card.
public nonisolated struct SettingsPageLayout: Sendable {
    /// A part of a category that is not a schema row (host lists, the theme
    /// studio, file actions). Raw values are the export's card ids.
    public nonisolated enum Card: String, Sendable, Hashable, CaseIterable {
        case themeStudio, terminalInfo, ghosttyDiagnostics, computerUse, harnesses, spaces, browserProfiles
        case machines, accounts, agentHarnesses, agentIntegrations, chiefs, advancedInfo, advancedActions, backdrops, mobile, devices, chiefPet
        /// The density tiles, preview and custom density editor (plans/cmux-next/density-DESIGN.md).
        case density
        /// What this Mac has that cmux can bring over (CmuxNextImportCards), every card found.
        case importSuggestions
        /// Every release channel's recent builds, with the one this Mac runs (Settings > Updates).
        case channels
        /// The web UI served now, its last check and Roll Back (plans/cmux-next/web-ota.md); NIGHTLY only.
        case webUpdates
        /// Settings > Chief's Voice input row: the Debug toggle home.voiceInput, only where it exists.
        case voiceInput
        /// Settings > Accounts: this Mac's own tailnet node (sign-in, address, Pair), Labs only.
        case tailnet
        /// Settings > Chief's Notices row: it opens Notifications, which holds the Chief's notices.
        case notices
        /// Settings > Server: each server's status, version line, Restart Recommended, socket and tailnet
        /// address (plans/cmux-next/server-updates-DESIGN.md section 10).
        case server
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
        /// Shown only in DEV builds: the page hides it when the host says it is not one.
        public var devOnly = false
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
                // Show All Chats on New Tab keeps its `sidebar.` key from when All chats was a sidebar section.
                group("settings.group.window"), GroupSpec(group: "settings.group.tabs", keys: ["sidebar.showChats"]),
                group("settings.group.columns"), group("settings.group.autoArchive"),
                group("settings.group.history"), group("settings.group.quit"), group("settings.group.picker"),
                group("settings.group.tasks"), group("settings.group.diffViewer"), group("settings.group.markdownViewer"),
                // The Screenshots pane's folders sit beside the other file-viewer groups.
                group("settings.group.files"), group("settings.group.screenshots"),
                group("settings.group.announcements"), group("settings.group.chats"),
            ],
            trail: [.spaces], actions: [.general, .rooms], aliases: [.general, .rooms]),
        // How this Mac updates, then every channel's recent builds (docs/release-rings.md in hq).
        CategorySpec(
            id: "updates", title: SettingsText.keyed("settings.category.updates", "Updates"), symbol: "icloud.and.arrow.down",
            groups: [
                group("settings.group.updates"),
                GroupSpec(keys: ["updates.idleInstallMaxWaitSeconds", "updates.idleInstallQuietSeconds"],
                          title: SettingsText.keyed("settings.pageGroup.updatesAdvanced", "Updates: Advanced")),
            ],
            // After the groups: the Web UI card (the web half of Updates; NIGHTLY only), then the channels.
            trail: [.webUpdates, .channels]),
        CategorySpec(
            id: "theme", title: SettingsText.keyed("settings.category.theme", "Theme"), symbol: "paintpalette",
            // appearance.theme and appearance.appTheme are drawn by the theme
            // studio (search still shows them as rows).
            groups: [group("settings.group.appTheme")],
            lead: [.themeStudio]),
        CategorySpec(
            id: "appearance", title: section(.appearance), symbol: "paintbrush",
            groups: [
                // Motion holds ui.animations.enabled and the per-area switches (f35023e54c1c);
                // without a group here they had no row on the page.
                group("settings.group.terminalFont"), group("settings.group.densityMotion"), group("settings.group.motion"),
                group("settings.group.colorTransition"),
                group("settings.group.windowBackground"), group("settings.group.panes"), group("settings.group.focusRing"),
                group("settings.group.sidebar"), group("settings.group.workspaceRows"),
                group("settings.group.statusIndicator"), group("settings.group.surfaces"),
            ],
            // Change Background… lands here: the art picker draws appearance.background and
            // appearance.backgroundOpacity (search still shows them as rows).
            // The density card draws appearance.density, .customDensity and .customDensities.
            lead: [.backdrops, .density], actions: [.appearance], aliases: [.appearance]),
        CategorySpec(
            id: "terminal", title: section(.terminal), symbol: "terminal",
            groups: [
                GroupSpec(keys: ["newTerminal.opensWorkspace", "app.warnBeforeClosingTab"],
                          title: SettingsText.keyed("settings.pageGroup.terminalBehavior", "Behavior")),
            ],
            lead: [.terminalInfo], trail: [.ghosttyDiagnostics], actions: [.terminal], aliases: [.terminal]),
        // The Monaco code editor: VS Code's settings by name. The Markdown Viewer group (its text
        // size too) lives in General beside Diff Viewer; a row has one home.
        CategorySpec(
            id: "editor", title: section(.editor), symbol: "chevron.left.forwardslash.chevron.right",
            groups: [
                group("settings.group.editorDefaults"), group("settings.group.editorFont"), group("settings.group.editorText"),
                group("settings.group.editorDisplay"), group("settings.group.editorCursor"), group("settings.group.editorEditing"),
                group("settings.group.editorSaving"),
            ],
            actions: [.editor], aliases: [.editor]),
        CategorySpec(
            id: "agents", title: SettingsText.keyed("settings.category.agents", "Agents"), symbol: "sparkles",
            groups: [
                GroupSpec(group: "settings.group.agentChat", keys: ["app.warnBeforeClosingAgentSession"]),
                group("settings.group.computerUse"),
                // The free AI model while signed out (cx-ds09i).
                group("settings.group.freeModel"),
                // What this Mac does while agents work (keep awake).
                group("settings.group.sessions"),
                // Whether agent sessions may start sub-sessions, how many and how deep.
                group("settings.group.subsessions"),
                // Folders that start an agent without the trust question.
                group("settings.group.folderTrust"),
            ],
            // Harnesses lists every harness; Your Agents (BRING-YOUR-OWN-HARNESS) adds, checks and
            // removes the ones you added. Agent integrations (optional help, collapsed) installs the
            // hooks that report an agent's state, through `cmux agent hook`.
            trail: [.harnesses, .agentHarnesses, .computerUse, .agentIntegrations]),
        // Every Chief setting on one page (Leo 2026-10-20: the name pill's popover is the quick
        // version; its All Chief Settings link opens this): Chiefs lists every Chief, each opening
        // its editor (name, picture, backend; u2586); the Chief Pet card (ChatGPT's Mini & Pets)
        // draws the preview, Show/Hide and the characters from its group's two rows; then the
        // chat's look. Voice input (the message box's mic) shows only in builds with Debug Settings.
        // Notices last: a row that opens Notifications (the Chief's notices are the app's
        // notifications; their rows keep their one home there).
        CategorySpec(
            id: "chief", title: SettingsText.keyed("settings.category.chief", "Chief"), symbol: "crown",
            groups: [
                // How the Chief chat's bubbles look (the theme's colours, or iMessage's).
                group("settings.group.chiefChat"),
                // The Chief pet floating over every app, and its character.
                group("settings.group.chiefPet"),
                // Which Chief Home opens; the Chiefs card draws it as its Engine row.
                group("settings.group.chiefEngine"),
                // Whether a tapback on a Chief message can start a turn, and the classifier that decides (a416).
                group("settings.group.chiefReactions"),
            ],
            lead: [.chiefs, .chiefPet, .voiceInput], trail: [.notices]),
        // A core cmux feature: banners, sounds, the attention ring and the
        // feed for agents, terminal programs and `cmux notify`.
        CategorySpec(
            id: "notifications", title: section(.notifications), symbol: "bell",
            groups: [
                // Sounds: per-event sounds, volume, timing and the burst cooldown
                // (NotificationSoundSettingsSchema); its per-level maps stay off the page.
                group("settings.group.banners"), group("settings.group.sounds"), group("settings.group.dismissal"),
                group("settings.group.attention"),
                group("settings.group.feedMirror"), group("settings.group.githubInbox"),
            ],
            actions: [.notifications], aliases: [.notifications]),
        CategorySpec(
            id: "browser", title: section(.browser), symbol: "globe",
            groups: [
                group("settings.group.engine"), group("settings.group.addressBar"), group("settings.group.toolbar"), group("settings.group.media"),
                group("settings.group.bookmarks"), group("settings.group.agentInput"), group("settings.group.extensions"),
                group("settings.group.links"), group("settings.group.openingLinks"), group("settings.group.passwords"),
                group("settings.group.import"), group("settings.group.memory"), group("settings.group.remote"),
            ],
            trail: [.browserProfiles], actions: [.browser], aliases: [.browser]),
        // Bring things over from other browsers, agents and terminals on this Mac.
        CategorySpec(
            id: "import", title: SettingsText.keyed("settings.category.import", "Import"), symbol: "square.and.arrow.down",
            groups: [], lead: [.importSuggestions]),
        CategorySpec(
            id: "keyboard", title: section(.keyboard), symbol: "keyboard",
            groups: [
                group("settings.shortcuts.hintsGroup"),
                GroupSpec(keys: ["tabs.commandDigits", "sidebar.numbering", "sidebar.cmd9", "sidebar.stepping", "sidebar.steppingWraps"],
                          title: SettingsText.keyed("settings.pageGroup.sidebarKeys", "Sidebar Navigation")),
                group("settings.group.palette"), group("settings.group.macScreenKeyboard"),
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
                GroupSpec(group: "settings.group.hangReports"),
                // The hosts an ssh:// link from another app reaches without asking (ExternalLinkGate).
                GroupSpec(group: "settings.group.sshLinks"),
            ],
            actions: [.home], aliases: [.home]),
        CategorySpec(
            id: "accounts", title: section(.accounts), symbol: "person.crop.circle",
            // Phone access sits beside the account it signs in with and the machines list. The
            // Machines card draws Machine Colors on its rows (a color well per machine).
            groups: [group("settings.group.phone"), group("settings.group.messagesServer"), group("settings.group.machineColors")],
            lead: [.accounts, .machines, .tailnet], actions: [.accounts, .machines], aliases: [.accounts, .machines]),
        // Phones reaching this Mac: the iPhone host's switch, then its live status and phones.
        CategorySpec(
            id: "mobile", title: SettingsText.keyed("settings.category.mobile", "Mobile"), symbol: "iphone",
            groups: [group("settings.group.mobile")], trail: [.mobile]),
        // The servers behind the app (cmux-tui, acpmux): status, versions, restart when one is older.
        CategorySpec(
            id: "server", title: SettingsText.keyed("settings.category.server", "Server"), symbol: "server.rack",
            groups: [], lead: [.server]),
        // This Mac and the person's other devices on the device hub: names, fingerprints, Mac
        // Screen access, relays and the access history (docs/device-hub). Every build: NIGHTLY and
        // Release use the built-in hub (DeviceHubSettings.resolvedBaseURL), and Mac Screen's
        // sharing switch, permissions and relays live only here.
        CategorySpec(
            id: "devices", title: SettingsText.keyed("settings.category.devices", "Devices"), symbol: "laptopcomputer",
            groups: [], lead: [.devices]),
        CategorySpec(
            id: "advanced", title: section(.advanced), symbol: "curlybraces", groups: [],
            lead: [.advancedInfo], trail: [.advancedActions], actions: [.advanced], aliases: [.advanced]),
        CategorySpec(
            id: "experimental", title: SettingsText.keyed("settings.category.experimental", "Experimental"),
            symbol: "flask",
            groups: [
                GroupSpec(group: "settings.group.labs", keys: ["appearance.experimentalControls"]),
                group("settings.group.appearanceTuning"),
            ]),
        CategorySpec(
            id: "development", title: section(.development), symbol: "hammer",
            groups: [group("settings.group.macScreen"), group("settings.group.deviceHub")], aliases: [.development], devOnly: true),
    ]
}
