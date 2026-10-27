/// Which schema keys an agent may change (MCP `settings_set` and
/// `settings_reset`; plans/cmux-next/settings-react.md section 3). Every key
/// is in exactly one of the two tables, with no default (the 18 surface
/// background rows join the settable table as one decided group, R55):
/// `SettingsSchemaExportTests` fails on a key in neither or both, so a new
/// setting cannot reach agents without a decision. Enforced at the one write
/// path, `SettingsController.setSetting(_:to:by:)` (`SettingWriter`): every
/// caller that is not the user (socket cli/mcp/script/remote, palette actions
/// run from the socket, pages without a user gesture) may change only these keys.
extension SettingsSchema {
    /// Why an agent may not change a key.
    public nonisolated enum AgentRefusal: String, Sendable, Hashable {
        /// The key decides what leaves the machine or what is recorded.
        case privacy
        /// The key opens network access or egress.
        case network
        /// The key can end terminals or other work.
        case destructive
        /// The person decides it; agents do not, in v1 (`picker.pinned`:
        /// which folders the picker offers first).
        case userOnly
    }
    /// Keys an agent may set and reset: the table below plus every
    /// `appearance.surfaces.<surface>.color|opacity` row (looks only, R55).
    public static let agentSettableKeys: Set<String> = agentSettableTable.union(SurfaceBackgroundSetting.keys).union(BrowserLinkClickSchema.agentSettableKeys)
        .union(OmnibarSettingsSchema.agentSettableKeys)
        .union(NotificationSoundSettingsSchema.agentSettableKeys) // notification sounds per event and level (sound only)
        .union(ChiefReactionSettings.keys) // a Chief configures its own reaction classifier (Lawrence 2026-10-21)
        // What sidebar rows show (looks only, SIDEBAR-ROWS-MINIMAL-AND-CUSTOMIZABLE).
        .union(WorkspaceRowSetting.keys)
        // The diff page's display keys (looks only, diff-host S4).
        .union(DiffViewerSettingsSchema.keys)
        .union(MarkdownViewerSettingsSchema.agentSettableKeys) // the markdown viewer's looks only
        .union(AgentPaneDisplaySettingsSchema.keys) // the agent chat's fonts, sizes and width (looks only)
        // The code editor's looks and editing behavior (diff-host S7); `editor.importFrom` is the person's.
        .union(EditorSettingsSchema.agentSettableKeys)
        .union(PanePlacementSettingsSchema.agentSettableKeys) // where new panes open (layout choices, like layout.dockColumnMode)
        .union(WorkspaceListSettingsSchema.agentSettableKeys) // new workspace position, computer headers (list shape)
        // Sizes and cmux-browser's own keys: cmux-browser writes them from its UI as `script`
        // (a separate process is never `user`), for example the sidebar width after a resize.
        .union(LayoutMetricSetting.all.map { $0.configPath.joined(separator: ".") })
        .union(BrowserAppSettingsSchema.descriptors.map(\.id))
        // The edited-files card (looks only).
        .union(AgentPaneEditedFilesSettingsSchema.agentSettableKeys)
.union(["agentPane.zoom"]) // display-only agent surface zoom
        .union(AgentPaneComposerSettingsSchema.agentSettableKeys) // the composer's context ring and mic (looks only)
        .union(HomeSettingsSchema.agentSettableKeys) // the Chief chat's bubble style (looks only)

    private static let agentSettableTable: Set<String> = [
        "window.titlebar",
        "shortcuts.showModifierHoldHints",
        "window.titlebarButtons",
        "tabs.plusButton",
        "tabs.barPosition", "tabs.barOrder", "tabs.toolbarButtons", "browser.toolbarPosition",
        "navigation.historyScope", "navigation.history.scope",
        "sidebar.minimalMode", "sidebar.minimal", "sidebar.density", "sidebar.detailedStatusIcons", "sidebar.showTimestamps", "sidebar.showColors",
        "sidebar.showLocalMachine", "workspaceColors.indicatorStyle",
        "sidebar.groupHeader.memberCount", "sidebar.groupHeader.unreadCount",
        "sidebar.numbering", "sidebar.cmd9", "sidebar.stepping", "sidebar.steppingWraps",
        "sidebar.side", "sidebar.style",
        "sidebar.spacesPosition", "sidebar.spacesVisibility",
        "tabs.newTabTemplate",
        "tabs.newTabPosition",
        "newTerminal.opensWorkspace",
        "tabs.cmdWClosesPinnedTabs",
        "tabs.terminalFirst",
        "app.hideDockIconWithoutWindows", // Dock icon and Cmd-Tab entry with no window open; ends no work
        "tabs.overflow",
        "tabs.swapCmdTAndCmdN",
        "tabs.commandDigits",
        "palette.scopes.tabs.prefix",
        "palette.scopes.workspaces.prefix",
        "palette.scopes.commands.prefix",
        "palette.scopes.settings.prefix",
        "palette.scopes.scopes.prefix",
        "tasks.layout",
        "layout.defaultColumnWidth",
        "layout.centerFocusedColumn",
        "layout.stripScrollbar",
        "layout.closeFocus",
        "layout.splitSizing",
        "layout.newColumnWidth",
        "layout.dockColumnEdge",
        "layout.dockColumnMode",
        "layout.frameOrientation",
        "layout.rows",
        "layout.focusFollowsMouse",
        "layout.scrollAreas",
        "layout.scrollModifier",
        "layout.minimumPaneWidth",
        "layout.minimumPaneHeight",
        "appearance.theme",
        "appearance.appTheme",
        "appearance.accent",
        "appearance.themeEdits",
        "appearance.machineColors", // the color of each machine's marks (looks only)
        "appearance.backdropArt",
        "appearance.backgroundOpacity",
        "appearance.backgroundBlur",
        "appearance.inactiveWindowDim",
        "appearance.wallpaperTint",
        "appearance.background",
        "appearance.backgroundRotation",
        "appearance.paneBackgrounds",
        "ui.reducedBackgrounds",
        "appearance.experimentalControls",
        "app.uiScale",
        "appearance.glassTransparency",
        "appearance.hue",
        "appearance.saturation",
        "appearance.density",
        "appearance.customDensity",
        "appearance.customDensities",
        "appearance.metrics.chromeFontSize",
        "appearance.interfaceScale",
        "appearance.borders",
        "appearance.sidebarSurface",
        "appearance.chromeStyle",
        "appearance.focusIndicator",
        "focus.inactiveTabStyle",
        "ui.animationSpeed",
        "ui.animations.newTab",
        "ui.animations.newWorkspace",
        "ui.animations.bounce",
        "ui.animations.enabled",
        "ui.animations.sidebar",
        "ui.animations.tabs",
        "ui.animations.panes",
        "ui.animations.overlays",
        "ui.animations.hoverCards",
        "ui.animations.home",
        "ui.animations.cursor",
        "ui.animations.indicators",
        "ui.animations.feedback",
        "ui.animations.web",
        "ui.paneAnimations",
        "ui.calm",
        "appearance.colorTransition.enabled",
        "appearance.colorTransition.duration",
        "appearance.colorTransition.curve",
        "appearance.colorTransition.springResponse",
        "appearance.colorTransition.springDamping",
        "appearance.colorTransition.bezierX1",
        "appearance.colorTransition.bezierY1",
        "appearance.colorTransition.bezierX2",
        "appearance.colorTransition.bezierY2",
        "appearance.colorTransition.colorSpace",
        "appearance.colorTransition.reduceMotion",
        "layout.panePadding",
        "layout.paneCornerRadius",
        "layout.paneBorder",
        "layout.paneSeparation",
        "sidebar.border",
        "sidebar.borderWidth",
        "layout.paneBorderColor",
        "layout.paneBorderWidth",
        "focusRing.enabled",
        "focusRing.style",
        "focusRing.contrast",
        "focusRing.color",
        "focusRing.width",
        "focusRing.showWhenSinglePane",
        "appearance.statusIndicator.style",
        "appearance.statusIndicator.animation",
        "appearance.statusIndicator.size",
        "appearance.statusIndicator.thickness",
        "appearance.statusIndicator.color",
        "appearance.statusIndicator.honorStatusStyle",
        "appearance.statusIndicator.showAgentWorkingOnTabs",
        "appearance.statusIndicator.showPageLoading",
        "status.inferCommandBusy",
        "status.inferCommandBusyAfter",
        "terminal.fontFamily",
        "terminal.fontSize",
        "sidebar.sectionLook",
        "sidebar.topBandMaxShare",
        "sidebar.bottomBandMaxShare",
        "sidebar.pinnedBandsScroll", "sidebar.showWorkspaceTabs", "sidebar.noFade", "sidebar.showChats", "sidebar.sessionTree",
        "sidebar.cards.tips", "sidebar.hoverCards.enabled", "sidebar.hoverCards.delay", "sidebar.hoverCards.layout", "sidebar.hoverCards.maxRows",
        "sidebar.hoverCards.sections.timings", "sidebar.hoverCards.sections.prompts", "sidebar.hoverCards.sections.waiting",
        "sidebar.hoverCards.sections.git", "sidebar.hoverCards.sections.ports", "sidebar.hoverCards.groups.workspaceGroups", "sidebar.hoverCards.groups.tabGroups",
        "sidebar.hoverCards.groups.delay", "sidebar.hoverCards.groups.order", "sidebar.hoverCards.groups.maxMembers",
        "sidebar.hoverCards.groups.sections.status", "sidebar.hoverCards.groups.sections.members",
        "sidebar.hoverCards.groups.sections.activity", "sidebar.hoverCards.groups.sections.git",
        "sidebar.hoverCards.groups.sections.ports", "sidebar.nowPlaying.enabled", "tabs.newTabNowPlaying", "media.pictureInPicture.enabled", "tabs.newTabWidgets.greeting", "tabs.newTabWidgets.projects", "tabs.newTabWidgets.actions", "tabs.newTabWidgets.chats", "tabs.newTabWidgets.styleDots", "tabs.newTabWidgets.order", "tabs.newTabWidgets.machines", "tabs.newTabWidgets.clock", "tabs.newTabWidgets.timer", "tabs.newTabWidgets.warmGreeting", "tabs.newTabWidgets.quote", "sidebar.showProjects", "sidebar.showSpaces", "sidebar.showProfileControl", "sidebar.showSearchButton", "sidebar.groupBy",
        "sidebar.priorityView.enabled", "sidebar.priorityView.shown",
        "browser.defaultEngine",
        "browser.siteEngines",
        "browser.newTabPage",
        "browser.showBookmarksBar",
        "browser.toolbarButtons",
        "browser.hibernation",
        "browser.hibernationExclusions",
        "browser.hibernatePinnedTabs",
        "browser.freezeHiddenTabs",
        "browser.keepNeighborTabsAwake",
        "notifications.dismissal",
        "notifications.timeoutSeconds",
        "notifications.sources.agent.dismissal",
        "notifications.sources.terminal.dismissal",
        "notifications.sources.cli.dismissal",
        "notifications.desktop",
        "notifications.sound",
        "notifications.quietHours",
        "notifications.suppressWhileTypingSeconds",
        "status.runNotifyMinimumSeconds",
        "status.runNotifyWhenVisible",
        "notifications.dockBadge",
        "notifications.attention.style",
        "notifications.attention.color",
        "notifications.attention.terminals",
        "notifications.attention.agentChats",
        "notifications.attention.agentChatBlinkCount",
        "notifications.attention.width",
        "notifications.attention.blinkCount",
        "notifications.attention.duration",
        "notifications.attention.persist",
        "notifications.attention.flash",
        "notifications.attention.flashOnTyping",
        "notifications.attention.showOnTab",
        "notifications.attention.showOnSidebar",
        "notifications.attention.moveToTop",
        // cmux-browser mutes a workspace through settings.set as `script` (cmux-browser #614).
        "notifications.mutedWorkspaces",
        "labs.previewFeatures",
        "labs.classicHome",
        // Which Home entries the sidebar shows (looks only; `cmux home enable-channels` runs as an agent writer).
        "home.channelsEnabled",
        // The floating Chief pet and its character: a display the person can hide again; its reply
        // box types only what the person writes.
        "home.chiefPetEnabled",
        "home.chiefPetMascot",
        // Needs you in the agent chat header (an App Store item): a display the person can hide again.
        "agentPane.needsYou.enabled",
        "updates.notify",
        "updates.showWhatsNew",
        "announcements.enabled",
    ]

    /// Keys an agent may not set or reset, with the reason.
    public static let agentRefusedKeys: [String: AgentRefusal] = Dictionary(uniqueKeysWithValues: OmnibarSettingsSchema.privacyKeys.map { ($0, AgentRefusal.privacy) })
        .merging(refusedTable) { first, _ in first }
        .merging(BrowserPasswordsSettingsSchema.refusedKeys) { first, _ in first }
        .merging(BrowserVerificationAutofillSettingsSchema.refusedKeys) { first, _ in first }

    private static let refusedTable: [String: AgentRefusal] = [
        // What leaves the machine: a device proof to the Cloud service (cx-ds09i).
        "freeModel.enabled": .privacy,
        "agents.chats.roots": .privacy,
        "agents.chats.discovery": .privacy,
        "agentPane.scrollToBottomOnSend": .userOnly,
        "agents.chats.enabled": .privacy,
        "picker.pinned": .userOnly,
        // Whether workspaces leave the sidebar on their own: the person decides (auto-archive-DESIGN.md).
        "workspaces.autoArchive.style": .userOnly, "workspaces.autoArchive.idleDays": .userOnly,
        // Which of the person's folders the Screenshots page reads.
        "screenshots.findTools": .privacy, "screenshots.folders": .privacy,
        // A pin leads the empty palette and an alias wins its word: an agent could put Close Window
        // under the user's Return.
        "palette.aliases": .userOnly, "palette.pins": .userOnly,
        "history.terminalCommands": .privacy,
        "history.commandRetentionDays": .privacy,
        "history.closed.maxGroups": .privacy,
        "history.closed.maxAgeDays": .privacy,
        "feed.mirrorNotifications.agents": .privacy,
        "feed.mirrorNotifications.terminal": .privacy,
        // An agent must not turn on sending its own prompts to the phone (cx-aocz).
        "feed.agentPermissionPrompts": .privacy,
        "feed.github.enabled": .network,
        "feed.github.pollIntervalSeconds": .network,
        "browser.remoteLocalhost": .network,
        // The weather widget asks Open-Meteo (and names a city) only once the person turns it on.
        "tabs.newTabWidgets.weather": .network,
        "tabs.newTabWidgets.weatherCity": .network,
        // Off, Chromium tabs load ads and trackers again.
        "browser.builtInAdBlocker": .privacy,
        // On, merely opening attacker-authored Markdown contacts its web image hosts.
        "markdown.remoteImages": .privacy,
        // Off, a person no longer sees what an agent clicks and types: an agent must not hide itself.
        "browser.showAgentCursor": .userOnly,
        // How agents move the pointer is the person's choice: an agent must not make itself faster or slower.
        "browser.agentMouse.motion": .userOnly,
        "browser.agentMouse.maxMoveMs": .userOnly,
        // Links the person sends to their default browser (a bank, SSO) must not move into a browser agents drive.
        "browser.openLinksInCmuxBrowser": .privacy,
        // Off, the person's links leave cmux and no page opens: an agent must not turn the browser it drives off or on.
        "browser.enabled": .userOnly,
        // On, agents can ask to read another browser's cookies and data again (`browser.importCookies`, `import.suggest`).
        "browser.import.enabled": .privacy,
        "browser.openTerminalLinksInCmuxBrowser": .privacy,
        // The app that opens your files from a menu: an agent must not pick what runs them.
        "files.textEditor": .userOnly,
        // Where a terminal program's URLs open, and a command that may run for each: an agent must
        // not pick what runs or move a sign-in page into a browser it drives.
        "terminal.linkOpener.default": .userOnly,
        "terminal.linkOpener.rules": .userOnly,
        // Which of the person's editor settings files cmux reads (VS Code, Zed...).
        "editor.importFrom": .userOnly,
        "browser.hostsToOpenInEmbeddedBrowser": .privacy,
        "browser.urlsToAlwaysOpenExternally": .privacy,
        // On, the sidebar and New Tab show what other apps play: an agent must not turn on reading them.
        "sidebar.nowPlaying.otherApps": .privacy,
        // Whether attached photos and videos send their location.
        "home.attachments.keepLocation": .privacy,
        // Where the person's direct messages and group chats go: an agent must not move them to another server.
        "home.server": .privacy,
        // Whether the person's Chief runs on this Mac or in the cloud: where their messages go.
        "home.chiefEngine": .privacy,
        // A reply's file link outside the project, and a reply's web image (D4, D5).
        "agentPane.links.outsideRoots": .privacy,
        "agentPane.images.remote": .network,
        "app.quitBehavior": .destructive,
        // On, a key is taken from every other app system-wide.
        "app.globalHotKey": .userOnly,
        "app.startAgentGlobalHotKey": .userOnly,
        // Off, a close ends running programs and agents without asking.
        "app.warnBeforeClosingTab": .destructive,
        "app.warnBeforeClosingAgentSession": .destructive,
        // Update checks and downloads reach the network; install on quit
        // replaces the app.
        "updates.checkAutomatically": .network,
        "updates.checkIntervalSeconds": .network,
        "updates.downloadAutomatically": .network,
        "updates.meteredNetwork": .network,
        // Which builds this Mac installs (a faster ring runs less-tested code): the person's call.
        "updates.channel": .userOnly,
        // Web UI updates download and run new page code from files.cmux.com.
        "updates.web": .network,
        // How long a nightly waits before it restarts into an update: the person's call.
        "updates.idleInstallMaxWaitSeconds": .userOnly,
        "updates.idleInstallQuietSeconds": .userOnly,
        "announcements.fetch": .network,
        // Whether this Mac sends hang reports (stacks and timings) to cmux: the person's choice only.
        "diagnostics.hangReports": .privacy,
        // On, cmux starts a helper that sees and controls other apps; only the person turns it on.
        // What a new chat may do without asking: an agent must not widen its own approvals.
        "agents.defaultPermissionMode": .userOnly,
        "computerUse.enabled": .userOnly,
        "computerUse.driver": .userOnly,
        // How hard cmux pulls the person back from another app: theirs to pick, not an agent's.
        "notifications.dockBounce": .userOnly,
        // Privacy: whether banners show what agents said is the person's call.
        "notifications.showPreviews": .userOnly,
        // Battery and sleep are the person's call: an agent must not keep the Mac up for itself.
        "sessions.keepAwake": .userOnly,
        // Whether agents start again by themselves after a restart is the person's call.
        "sessions.resumeAgents": .userOnly,
        // An agent must not let itself, or another agent, skip the person's approvals.
        "sessions.allowFullAccess": .destructive,
        // On, every agent gets tools that start child chats: the person turns that on.
        "sessions.promptSuggestions": .userOnly,
        // How many agent sessions an agent may start, and how deep, is the person's call: an agent
        // must not raise its own limits.
        "agents.subsessions.enabled": .userOnly,
        // Who answers a sub-session's questions is the person's call too.
        "agents.subsessions.answerQuestions": .userOnly,
        "agents.subsessions.maxChildren": .userOnly,
        "agents.subsessions.maxRunning": .userOnly,
        "agents.subsessions.maxDepth": .userOnly,
        // Which folders an agent may open without asking is the person's call: an agent must not
        // widen what it may open without asking.
        "agents.trust.autoTrust": .userOnly,
        "agents.trust.projectRoots": .userOnly,
        "agents.trust.ownOrgs": .userOnly,
        // Which hosts an ssh:// link from another app connects to without asking: only the person
        // trusts a host, so a page or an agent cannot add one and skip the confirmation.
        "ssh.linkAllowedHosts": .network,
        // What reaches this Mac from outside and what leaves it: only the person opens phone access.
        "phone.allowConnections": .network,
        "phone.startSessions": .network,
        "phone.keepAwake": .userOnly,
        // Workspace names leave this Mac for the Cloud service: only the person turns it on.
        "phone.cloudReplica": .privacy,
        // On, a phone signed in to the same account can open this Mac's terminals and agents.
        "mobile.allowIPhoneConnections": .userOnly,
        // Which device sizes a terminal shown on this Mac and a phone; the person sets it here or on the phone.
        "mobile.terminalSizing": .userOnly,
        "mobile.terminalSizingOrder": .userOnly,
        // On, a session event tap takes system chords from macOS for the other Mac; only the person turns it on.
        "macScreen.systemShortcuts": .userOnly,
        // Changes how this Mac's Mac Screen streams leave the network; only the person sets it.
        "macScreen.debug.relayOnly": .userOnly,
        // Chooses the server this Mac registers its device keys with; only the person sets it.
        "deviceHub.url": .userOnly,
        "updates.installOnQuit": .destructive,
        "updates.keepPreviousVersions": .destructive,
    ]

    /// True when an agent may change `descriptor`, false when it may not, nil
    /// when the key is in neither table (a schema error the tests catch).
    public static func agentSettable(_ descriptor: SettingDescriptor) -> Bool? {
        if agentSettableKeys.contains(descriptor.id) { return true }
        if agentRefusedKeys[descriptor.id] != nil { return false }
        return nil
    }
}
