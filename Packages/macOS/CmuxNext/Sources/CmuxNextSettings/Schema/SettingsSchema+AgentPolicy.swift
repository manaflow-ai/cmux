/// Which schema keys an agent may change (MCP `settings_set` and
/// `settings_reset`; plans/cmux-next/settings-react.md section 3). Every key
/// is listed explicitly in exactly one of the two tables, with no default:
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

    /// Keys an agent may set and reset.
    public static let agentSettableKeys: Set<String> = [
        "window.titlebar",
        "window.rail",
        "tabs.newTabKind",
        "layout.defaultColumnWidth",
        "layout.centerFocusedColumn",
        "layout.stripScrollbar",
        "layout.closeFocus",
        "layout.splitSizing",
        "layout.newColumnWidth",
        "layout.stickyColumnEdge",
        "layout.stickyColumnMode",
        "layout.frameOrientation",
        "layout.minimumPaneWidth",
        "layout.minimumPaneHeight",
        "appearance.theme",
        "appearance.backgroundOpacity",
        "appearance.backgroundBlur",
        "appearance.density",
        "appearance.metrics.chromeFontSize",
        "appearance.borders",
        "appearance.focusIndicator",
        "appearance.tabBarBackground",
        "focus.inactiveTabStyle",
        "ui.animationSpeed",
        "layout.panePadding",
        "layout.paneCornerRadius",
        "layout.paneBorder",
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
        "sidebar.stickyBandsScroll",
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
    ]

    /// Keys an agent may not set or reset, with the reason.
    public static let agentRefusedKeys: [String: AgentRefusal] = [
        "history.terminalCommands": .privacy,
        "feed.mirrorNotifications.agents": .privacy,
        "feed.mirrorNotifications.terminal": .privacy,
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
