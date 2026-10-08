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
        // What sidebar rows show (looks only, SIDEBAR-ROWS-MINIMAL-AND-CUSTOMIZABLE).
        .union(WorkspaceRowSetting.keys)
        // The diff page's display keys (looks only, diff-host S4).
        .union(DiffViewerSettingsSchema.keys)
        .union(PanePlacementSettingsSchema.agentSettableKeys) // where new panes open (layout choices, like layout.dockColumnMode)
        // Sizes and cmux-browser's own keys: cmux-browser writes them from its UI as `script`
        // (a separate process is never `user`), for example the sidebar width after a resize.
        .union(LayoutMetricSetting.all.map { $0.configPath.joined(separator: ".") })
        .union(BrowserAppSettingsSchema.descriptors.map(\.id))
        // The edited-files card (looks only).
        .union(AgentPaneEditedFilesSettingsSchema.agentSettableKeys)

    private static let agentSettableTable: Set<String> = [
        "window.titlebar",
        "shortcuts.showModifierHoldHints",
        "window.titlebarButtons",
        "tabs.plusButton",
        "tabs.barPosition", "tabs.barOrder",
        "navigation.historyScope", "navigation.history.scope",
        "sidebar.minimalMode",
        "sidebar.numbering", "sidebar.cmd9", "sidebar.stepping", "sidebar.steppingWraps",
        "sidebar.side",
        "sidebar.spacesPosition",
        "tabs.newTabKind",
        "newTerminal.opensWorkspace",
        "tabs.cmdWClosesPinnedTabs",
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
        "layout.minimumPaneWidth",
        "layout.minimumPaneHeight",
        "appearance.theme",
        "appearance.appTheme",
        "appearance.backdropArt",
        "appearance.backgroundOpacity",
        "appearance.backgroundBlur",
        "appearance.background",
        "appearance.experimentalControls",
        "app.uiScale",
        "appearance.glassTransparency",
        "appearance.hue",
        "appearance.saturation",
        "appearance.density",
        "appearance.metrics.chromeFontSize",
        "appearance.borders",
        "appearance.focusIndicator",
        "focus.inactiveTabStyle",
        "ui.animationSpeed",
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
        "sidebar.pinnedBandsScroll", "sidebar.showWorkspaceTabs", "sidebar.showChats",
        "sidebar.cards.tips",
        "browser.defaultEngine",
        "browser.newTabPage",
        "browser.showBookmarksBar",
        "browser.hibernation",
        "browser.hibernationExclusions",
        "browser.hibernatePinnedTabs",
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
        "notifications.attention.width",
        "notifications.attention.blinkCount",
        "notifications.attention.duration",
        "notifications.attention.persist",
        "notifications.attention.showOnTab",
        "notifications.attention.showOnSidebar",
        // cmux-browser mutes a workspace through settings.set as `script` (cmux-browser #614).
        "notifications.mutedWorkspaces",
        "labs.previewFeatures",
        "updates.notify",
        "updates.showWhatsNew",
        "announcements.enabled",
    ]

    /// Keys an agent may not set or reset, with the reason.
    public static let agentRefusedKeys: [String: AgentRefusal] = Dictionary(uniqueKeysWithValues: OmnibarSettingsSchema.privacyKeys.map { ($0, AgentRefusal.privacy) })
        .merging(refusedTable) { first, _ in first }

    private static let refusedTable: [String: AgentRefusal] = [
        "agents.chats.roots": .privacy,
        "agents.chats.discovery": .privacy,
        "agents.chats.enabled": .privacy,
        "picker.pinned": .userOnly,
        "history.terminalCommands": .privacy,
        "feed.mirrorNotifications.agents": .privacy,
        "feed.mirrorNotifications.terminal": .privacy,
        "feed.github.enabled": .network,
        "feed.github.pollIntervalSeconds": .network,
        "browser.remoteLocalhost": .network,
        // Whether attached photos and videos send their location.
        "home.attachments.keepLocation": .privacy,
        // A reply's file link outside the project, and a reply's web image (D4, D5).
        "agentPane.links.outsideRoots": .privacy,
        "agentPane.images.remote": .network,
        "app.quitBehavior": .destructive,
        // On, a key is taken from every other app system-wide.
        "app.globalHotKey": .userOnly,
        // Off, a close ends running programs and agents without asking.
        "app.warnBeforeClosingTab": .destructive,
        "app.warnBeforeClosingAgentSession": .destructive,
        // Update checks and downloads reach the network; install on quit
        // replaces the app.
        "updates.checkAutomatically": .network,
        "updates.checkIntervalSeconds": .network,
        "updates.downloadAutomatically": .network,
        "updates.meteredNetwork": .network,
        "announcements.fetch": .network,
        // On, cmux starts a helper that sees and controls other apps; only the person turns it on.
        "computerUse.enabled": .userOnly,
        "computerUse.driver": .userOnly,
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
