public import CmuxNextActions
public import CmuxNextDesign
public import CoreGraphics

/// Every cmux.json setting the Settings window edits, in display order. A
/// new setting is one descriptor here (plus its parser): the window, write
/// validation and the palette's Toggle Setting pick it up, and
/// `SettingsSchemaTests` fails until the parser accepts every value the
/// descriptor allows and rejects the rest.
public nonisolated enum SettingsSchema {
    public static var all: [SettingDescriptor] {
        general + columnLayout + palette + picker + tasks + appearance + terminal + sidebarSections + browser + notifications + labs + feed
    }

    /// Keys Reset All Settings leaves alone: the look picked at onboarding
    /// (the app theme and the terminal font), which each row still resets.
    public static let keptOnResetAll: Set<[String]> = [
        AppThemeSetting().configPath, TerminalFontSetting().familyPath, TerminalFontSetting().sizePath,
    ]

    /// The descriptors of one section, in order.
    public static func settings(in section: SettingsSection) -> [SettingDescriptor] {
        all.filter { $0.section == section }
    }

    /// The descriptor for a dotted key or key path.
    public static func descriptor(for path: [String]) -> SettingDescriptor? {
        all.first { $0.path == path }
    }

    /// Actions shown as buttons at the end of a section (their titles and
    /// availability come from the action registry).
    public static func actions(in section: SettingsSection) -> [ActionID] {
        switch section {
        case .general: ["palette.welcomeChecklist", "palette.makeDefaultTerminal", "palette.makeDefaultBrowser", "palette.checkForUpdates"]
        case .appearance: ["appearance.customize", "space.setTheme", "workspace.setTheme", "terminal.setTheme", "palette.openGhosttySettings"]
        case .terminal: ["palette.openGhosttySettings", "reloadConfiguration"]
        case .browser: ["importFromBrowser", "browser.extensions.manage", "browser.extensions.webStore", "browser.extensions.loadUnpacked"]
        case .keyboard: ["palette.searchShortcuts"]
        case .notifications: []
        case .accounts: ["accounts.refresh", "openTeamPicker"]
        case .rooms: ["space.new", "space.switch", "space.rename", "space.setTheme", "space.clearTheme"]
        case .machines: ["remote.connect", "newCloudMachine", "palette.auth.signIn"]
        case .advanced: ["palette.openCmuxSettingsFile", "reloadConfiguration"]
        }
    }

    // MARK: General

    static var general: [SettingDescriptor] {
        let window = SettingsText.keyed("settings.group.window", "Window")
        let columns = SettingsText.keyed("settings.group.columns", "Columns")
        let quitting = SettingsText.keyed("settings.group.quit", "Quitting")
        let history = SettingsText.keyed("settings.group.history", "History")
        let tabs = SettingsText.keyed("settings.group.tabs", "Tabs")
        return [
            SettingDescriptor(
                TerminalCommandHistorySetting.configPath, section: .general, group: history,
                title: SettingsText.keyed("settings.history.terminalCommands", "Record Terminal Commands"),
                help: SettingsText.keyed("settings.history.terminalCommands.help",
                                        "Lists finished shell commands in History. Command lines can contain secrets."),
                kind: .toggle, default: .bool(TerminalCommandHistorySetting.fallback),
                keywords: ["history", "commands", "shell", "privacy", "osc 133"]
            ),
            SettingDescriptor(
                NavigationHistoryScopeSetting.configPath, section: .general, group: history,
                title: SettingsText.keyed("settings.navigation.historyScope", "Back and Forward"),
                help: SettingsText.keyed("settings.navigation.historyScope.help",
                                        "What Go Back and Go Forward walk: places in this workspace, in this window, or the focused page's own history."),
                kind: .choice([
                    SettingChoice("workspace", SettingsText.keyed("settings.navigation.historyScope.workspace", "Workspace")),
                    SettingChoice("window", SettingsText.keyed("settings.navigation.historyScope.window", "Window")),
                    SettingChoice("surface", SettingsText.keyed("settings.navigation.historyScope.surface", "Focused Page")),
                ]),
                default: .string(NavigationHistoryScopeSetting.fallback),
                keywords: ["history", "back", "forward", "navigation", "location", "scope"]
            ),
            SettingDescriptor(
                WindowTitlebarSetting.configPath, section: .general, group: window,
                title: SettingsText.keyed("settings.window.titlebar", "Titlebar"),
                help: SettingsText.keyed("settings.window.titlebar.help", "Minimal has no titlebar strip; the top row moves the window."),
                kind: .choice([
                    SettingChoice(TitlebarStyle.minimal.rawValue, SettingsText.keyed("settings.choice.minimal", "Minimal")),
                    SettingChoice(TitlebarStyle.standard.rawValue, SettingsText.keyed("settings.choice.standard", "Standard")),
                ]),
                default: .string(WindowTitlebarSetting.fallback.rawValue), keywords: ["traffic lights", "title"]
            ),
            SettingDescriptor(
                TitlebarButtonsSetting.configPath, section: .general, group: window,
                title: SettingsText.keyed("settings.window.titlebarButtons", "Titlebar Buttons"),
                help: SettingsText.keyed("settings.window.titlebarButtons.help",
                                        "On Hover hides Back and Forward until the pointer is over the top row. The sidebar button always shows."),
                kind: .choice([
                    SettingChoice(TitlebarButtonsMode.hover.rawValue, SettingsText.keyed("settings.choice.onHover", "On Hover")),
                    SettingChoice(TitlebarButtonsMode.always.rawValue, SettingsText.keyed("settings.choice.always", "Always")),
                ]),
                default: .string(TitlebarButtonsSetting.fallback.rawValue),
                keywords: ["titlebar", "buttons", "back", "forward", "hover", "hide", "traffic lights", "toolbar"]
            ),
            newTabKind(group: tabs),
            plusButton(group: tabs),
            ChromePlacementSetting.tabBarPositionDescriptor(group: tabs),
            newTerminalOpensWorkspace(group: tabs),
            SettingDescriptor(
                QuitBehaviorSetting.configPath, section: .general, group: quitting,
                title: SettingsText.keyed("settings.app.quitBehavior", "When Quitting"),
                help: SettingsText.keyed("settings.app.quitBehavior.help",
                                        "Terminals run in cmux-tui and keep running after cmux quits unless you end them."),
                kind: .choice([
                    SettingChoice(QuitBehavior.ask.rawValue, SettingsText.keyed("settings.choice.quitAsk", "Ask")),
                    SettingChoice(QuitBehavior.keep.rawValue, SettingsText.keyed("settings.choice.quitKeep", "Keep Sessions Running")),
                    SettingChoice(QuitBehavior.endKeepLayout.rawValue,
                                  SettingsText.keyed("settings.choice.quitEndKeepLayout", "End Sessions, Keep Layout")),
                    SettingChoice(QuitBehavior.endEverything.rawValue, SettingsText.keyed("settings.choice.quitEndEverything", "End Everything")),
                ]),
                default: .string(QuitBehaviorSetting.fallback.rawValue),
                keywords: ["quit", "exit", "sessions", "terminals", "cmux-tui", "daemon", "background"]
            ),
            SettingDescriptor(
                DefaultColumnWidthSetting.configPath, section: .general, group: columns,
                title: SettingsText.keyed("settings.layout.fixedColumnWidth", "Fixed Column Width"),
                help: SettingsText.keyed("settings.layout.fixedColumnWidth.help", "A share of the window width, for Fixed Width new columns."),
                kind: .number(SettingNumber(DefaultColumnWidthSetting.range, step: 0.05, unit: .fraction)),
                default: .number(DefaultColumnWidthSetting.fallback), keywords: ["width"]
            ),
            SettingDescriptor(
                CenterFocusedColumnSetting.configPath, section: .general, group: columns,
                title: SettingsText.keyed("settings.layout.centerFocusedColumn", "Center Focused Column"),
                kind: .choice([
                    SettingChoice(CenterFocusedColumn.never.rawValue, SettingsText.keyed("settings.choice.never", "Never")),
                    SettingChoice(CenterFocusedColumn.always.rawValue, SettingsText.keyed("settings.choice.always", "Always")),
                    SettingChoice(CenterFocusedColumn.onOverflow.rawValue, SettingsText.keyed("settings.choice.onOverflow", "When It Does Not Fit")),
                ]),
                default: .string(CenterFocusedColumnSetting.fallback.rawValue), keywords: ["scroll"]
            ),
            SettingDescriptor(
                StripScrollbarSetting.configPath, section: .general, group: columns,
                title: SettingsText.keyed("settings.layout.stripScrollbar", "Column Scroll Bar"),
                help: SettingsText.keyed("settings.layout.stripScrollbar.help", "A thin bar under the columns that shows and moves the visible range."),
                kind: .choice([
                    SettingChoice(StripScrollbarMode.auto.rawValue, SettingsText.keyed("settings.choice.stripScrollbarAuto", "While Scrolling")),
                    SettingChoice(StripScrollbarMode.always.rawValue, SettingsText.keyed("settings.choice.always", "Always")),
                    SettingChoice(StripScrollbarMode.off.rawValue, SettingsText.keyed("settings.choice.off", "Off")),
                ]),
                default: .string(StripScrollbarSetting.fallback.rawValue), keywords: ["scroll", "scrollbar", "minimap"]
            ),
            SettingDescriptor(
                CloseFocusSetting.configPath, section: .general, group: columns,
                title: SettingsText.keyed("settings.layout.closeFocus", "Focus After Closing a Pane"),
                help: SettingsText.keyed("settings.layout.closeFocus.help", "Which pane gets focus when the focused pane closes."),
                kind: .choice([
                    SettingChoice(CloseFocusPolicy.previousNeighbor.rawValue, SettingsText.keyed("settings.choice.closeFocusPreviousNeighbor", "Previous Neighbor")),
                    SettingChoice(CloseFocusPolicy.mostRecent.rawValue, SettingsText.keyed("settings.choice.closeFocusMostRecent", "Most Recently Focused")),
                ]),
                default: .string(CloseFocusSetting.fallback.rawValue), keywords: ["close", "focus", "neighbor", "recent"]
            ),
        ]
    }


    // MARK: Appearance

    static var appearance: [SettingDescriptor] { AppearanceSettingsSchema.descriptors + SurfaceSettingsSchema.descriptors + statusIndicator }

    static func points(_ range: ClosedRange<CGFloat>, step: Double, placeholder: Double? = nil) -> SettingNumber {
        SettingNumber(Double(range.lowerBound)...Double(range.upperBound), step: step, unit: .points, placeholder: placeholder)
    }
}
