/// Which schema keys an agent may change (MCP `settings_set` and
/// `settings_reset`; plans/cmux-next/settings-react.md section 3). Every key
/// is in exactly one of the two tables, with no default (the 18 surface
/// background rows join the settable table as one decided group, R55):
/// `SettingsSchemaExportTests` fails on a key in neither or both, so a new
/// setting cannot reach agents without a decision. The daemon's config actor
/// enforces the exported flag; MCP only forwards.
extension SettingsSchema {
    /// Why an agent may not change a key.
    public nonisolated enum AgentRefusal: String, Sendable, Hashable {
        /// The key decides what leaves the machine or what is recorded.
        case privacy
        /// The key opens network access or egress.
        case network
        /// The key can end terminals or other work.
        case destructive
    }
    /// Keys an agent may set and reset: the table below plus every
    /// `appearance.surfaces.<surface>.color|opacity` row (looks only, R55).
    public static let agentSettableKeys: Set<String> = agentSettableTable.union(SurfaceBackgroundSetting.keys)

    private static let agentSettableTable: Set<String> = [
        "window.titlebar",
        "window.titlebarButtons",
        "tabs.plusButton",
        "navigation.historyScope",
        "sidebar.minimalMode",
        "sidebar.side",
        "sidebar.spacesPosition",
        "tabs.newTabKind",
        "newTerminal.opensWorkspace",
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
        "appearance.backdropArt",
        "appearance.backgroundOpacity",
        "appearance.backgroundBlur",
        "appearance.background",
        "appearance.experimentalControls",
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
        "status.inferCommandBusy",
        "status.inferCommandBusyAfter",
        "terminal.fontFamily",
        "terminal.fontSize",
        "sidebar.sectionLook",
        "sidebar.topBandMaxShare",
        "sidebar.bottomBandMaxShare",
        "sidebar.pinnedBandsScroll", "sidebar.showWorkspaceTabs",
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
        "labs.previewFeatures",
    ]

    /// Keys an agent may not set or reset, with the reason.
    public static let agentRefusedKeys: [String: AgentRefusal] = [
        "history.terminalCommands": .privacy,
        "feed.mirrorNotifications.agents": .privacy,
        "feed.mirrorNotifications.terminal": .privacy,
        "feed.github.enabled": .network,
        "feed.github.pollIntervalSeconds": .network,
        "browser.remoteLocalhost": .network,
        "app.quitBehavior": .destructive,
    ]

    /// True when an agent may change `descriptor`, false when it may not, nil
    /// when the key is in neither table (a schema error the tests catch).
    public static func agentSettable(_ descriptor: SettingDescriptor) -> Bool? {
        if agentSettableKeys.contains(descriptor.id) { return true }
        if agentRefusedKeys[descriptor.id] != nil { return false }
        return nil
    }
}
