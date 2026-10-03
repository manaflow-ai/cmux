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
        general + columnLayout + appearance + terminal + sidebarSections + browser + notifications
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
                WindowRailSetting.configPath, section: .general, group: window,
                title: SettingsText.keyed("settings.window.rail", "Action Rail"),
                help: SettingsText.keyed("settings.window.rail.help",
                                        "Shows the sidebar's pinned sections as a column of icons beside it."),
                kind: .choice([
                    SettingChoice(WindowRailPlacement.off.rawValue, SettingsText.keyed("settings.choice.off", "Off")),
                    SettingChoice(WindowRailPlacement.leading.rawValue, SettingsText.keyed("settings.choice.railLeading", "Window Edge")),
                    SettingChoice(WindowRailPlacement.afterSidebar.rawValue,
                                  SettingsText.keyed("settings.choice.railAfterSidebar", "After Sidebar")),
                ]),
                default: .string(WindowRailSetting.fallback.rawValue), keywords: ["rail", "toolbar", "buttons", "inbox", "accounts"]
            ),
            newTabKind(group: tabs),
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

    static var appearance: [SettingDescriptor] {
        let look = SettingsText.keyed("settings.group.densityMotion", "Density and Motion")
        let panes = SettingsText.keyed("settings.group.panes", "Panes")
        let ring = SettingsText.keyed("settings.group.focusRing", "Focus Ring")
        let densityDefault = SettingsText.keyed("settings.default.density", "Density default")
        let theme = SettingsText.keyed("settings.default.theme", "Theme")
        let window = SettingsText.keyed("settings.group.windowBackground", "Window Background")
        let ghostty = SettingsText.keyed("settings.default.ghosttyConfig", "Ghostty config")
        let appTheme = SettingsText.keyed("settings.group.appTheme", "App Theme")
        return [
            SettingDescriptor(
                AppThemeSetting().configPath, section: .appearance, group: appTheme,
                title: SettingsText.keyed("settings.appearance.theme", "Theme"),
                help: SettingsText.keyed("settings.appearance.theme.help",
                                        "Colors for cmux and its terminals. A space, workspace or terminal theme overrides it."),
                kind: .theme, default: nil, defaultLabel: ghostty,
                keywords: ["theme", "color", "colors", "color scheme", "dark", "light", "ghostty", "palette"]
            ),
            SettingDescriptor(
                WindowBackgroundSetting.opacityPath, section: .appearance, group: window,
                title: SettingsText.keyed("settings.appearance.backgroundOpacity", "Opacity"),
                help: SettingsText.keyed("settings.appearance.backgroundOpacity.help",
                                        "How much of the theme color covers the material behind the window."),
                kind: .number(SettingNumber(WindowBackgroundSetting.opacityRange, step: 0.05, unit: .fraction, placeholder: 1)),
                default: nil, defaultLabel: ghostty,
                keywords: ["transparency", "translucent", "background-opacity", "blur", "glass"]
            ),
            SettingDescriptor(
                WindowBackgroundSetting.materialPath, section: .appearance, group: window,
                title: SettingsText.keyed("settings.appearance.backgroundBlur", "Material"),
                help: SettingsText.keyed("settings.appearance.backgroundBlur.help",
                                        "Unset, the window follows Ghostty's background-opacity and background-blur."),
                kind: .choice([
                    SettingChoice(WindowMaterialChoice.frosted.rawValue, SettingsText.keyed("settings.choice.frosted", "Frosted")),
                    SettingChoice(WindowMaterialChoice.glass.rawValue, SettingsText.keyed("settings.choice.glass", "Glass")),
                    SettingChoice(WindowMaterialChoice.glassClear.rawValue, SettingsText.keyed("settings.choice.glassClear", "Clear Glass")),
                    SettingChoice(WindowMaterialChoice.unblurred.rawValue, SettingsText.keyed("settings.choice.none", "None")),
                ]),
                default: nil, defaultLabel: ghostty,
                keywords: ["blur", "vibrancy", "liquid glass", "background-blur", "transparency"]
            ),
            SettingDescriptor(
                ["appearance", "density"], section: .appearance, group: look,
                title: SettingsText.keyed("settings.appearance.density", "Density"),
                kind: .choice([
                    SettingChoice("compact", SettingsText.keyed("settings.choice.compact", "Compact")),
                    SettingChoice("comfortable", SettingsText.keyed("settings.choice.comfortable", "Comfortable")),
                ]),
                default: "compact", keywords: ["size", "spacing"]
            ),
            SettingDescriptor(
                InterfaceSizeSetting().configPath, section: .appearance, group: look,
                title: SettingsText.keyed("settings.appearance.interfaceSize", "Interface Size"),
                help: SettingsText.keyed("settings.appearance.interfaceSize.help",
                                        "Text size of tabs, the sidebar and other controls. Terminal text has its own size."),
                kind: .number(SettingNumber(InterfaceSizeSetting().range, step: 1, unit: .points, placeholder: 12)),
                default: nil, defaultLabel: densityDefault,
                keywords: ["font", "text", "size", "zoom", "scale", "bigger", "smaller", "chromeFontSize"]
            ),
            SettingDescriptor(
                BordersSetting.configPath, section: .appearance, group: look,
                title: SettingsText.keyed("settings.appearance.borders", "Borders"),
                help: SettingsText.keyed("settings.appearance.borders.help", "None removes every border, hairline and separator in the app."),
                kind: .choice([
                    SettingChoice(BorderMode.default.rawValue, SettingsText.keyed("settings.choice.default", "Default")),
                    SettingChoice(BorderMode.none.rawValue, SettingsText.keyed("settings.choice.none", "None")),
                ]),
                default: .string(BordersSetting.fallback.rawValue), keywords: ["border", "hairline", "separator", "outline", "line"]
            ),
            SettingDescriptor(
                PaneFocusSettings.focusIndicatorPath, section: .appearance, group: look,
                title: SettingsText.keyed("settings.appearance.focusIndicator", "Focused Pane"),
                help: SettingsText.keyed("settings.appearance.focusIndicator.help",
                                        "How the focused pane stands out: its border, subtler tabs in the other panes, both or neither."),
                kind: .choice([
                    SettingChoice(FocusIndicator.border.rawValue, SettingsText.keyed("settings.choice.border", "Border")),
                    SettingChoice(FocusIndicator.tabs.rawValue, SettingsText.keyed("settings.choice.tabs", "Tabs")),
                    SettingChoice(FocusIndicator.both.rawValue, SettingsText.keyed("settings.choice.both", "Both")),
                    SettingChoice(FocusIndicator.none.rawValue, SettingsText.keyed("settings.choice.none", "None")),
                ]),
                default: .string(PaneFocusSettings.focusIndicatorFallback.rawValue), keywords: ["focus", "active", "pane", "tab", "ring"]
            ),
            SettingDescriptor(
                PaneFocusSettings.inactiveTabStylePath, section: .appearance, group: look,
                title: SettingsText.keyed("settings.focus.inactiveTabStyle", "Unfocused Pane Tabs"),
                help: SettingsText.keyed("settings.focus.inactiveTabStyle.help",
                                        "How the other panes' tabs draw subtler when Focused Pane marks tabs: Fade dims them, Tonal steps their text down, Quiet drops the selected pill."),
                kind: .choice([
                    SettingChoice(InactiveTabStyle.fade.rawValue, SettingsText.keyed("settings.choice.fade", "Fade")),
                    SettingChoice(InactiveTabStyle.tonal.rawValue, SettingsText.keyed("settings.choice.tonal", "Tonal")),
                    SettingChoice(InactiveTabStyle.quiet.rawValue, SettingsText.keyed("settings.choice.quiet", "Quiet")),
                ]),
                default: .string(PaneFocusSettings.inactiveTabStyleFallback.rawValue), keywords: ["focus", "inactive", "unfocused", "pane", "tab", "fade", "dim"]
            ),
            SettingDescriptor(
                AnimationSpeedSetting.configPath, section: .appearance, group: look,
                title: SettingsText.keyed("settings.ui.animationSpeed", "Animations"),
                kind: .choice([
                    SettingChoice(MotionSpeed.fast.rawValue, SettingsText.keyed("settings.choice.fast", "Fast")),
                    SettingChoice(MotionSpeed.normal.rawValue, SettingsText.keyed("settings.choice.normal", "Normal")),
                    SettingChoice(MotionSpeed.off.rawValue, SettingsText.keyed("settings.choice.off", "Off")),
                ]),
                default: .string(AnimationSpeedSetting.fallback.rawValue), keywords: ["motion", "speed"]
            ),
            SettingDescriptor(
                ["layout", "panePadding"], section: .appearance, group: panes,
                title: SettingsText.keyed("settings.layout.panePadding", "Padding"),
                kind: .number(points(PaneChromeOverrides.paddingRange, step: 1, placeholder: 4)),
                default: nil, defaultLabel: densityDefault
            ),
            SettingDescriptor(
                ["layout", "paneCornerRadius"], section: .appearance, group: panes,
                title: SettingsText.keyed("settings.layout.paneCornerRadius", "Corner Radius"),
                kind: .number(points(PaneChromeOverrides.cornerRadiusRange, step: 1, placeholder: 6)),
                default: nil, defaultLabel: densityDefault, keywords: ["rounded"]
            ),
            SettingDescriptor(
                ["layout", "paneBorder"], section: .appearance, group: panes,
                title: SettingsText.keyed("settings.layout.paneBorder", "Border"),
                kind: .choice([
                    SettingChoice(PaneBorderStyle.subtle.rawValue, SettingsText.keyed("settings.choice.subtle", "Subtle")),
                    SettingChoice(PaneBorderStyle.none.rawValue, SettingsText.keyed("settings.choice.none", "None")),
                ]),
                default: .string(PaneBorderStyle.subtle.rawValue)
            ),
            SettingDescriptor(
                ["layout", "paneBorderColor"], section: .appearance, group: panes,
                title: SettingsText.keyed("settings.layout.paneBorderColor", "Border Color"),
                kind: .color, default: nil, defaultLabel: theme
            ),
            SettingDescriptor(
                ["layout", "paneBorderWidth"], section: .appearance, group: panes,
                title: SettingsText.keyed("settings.layout.paneBorderWidth", "Border Width"),
                kind: .number(points(PaneChromeOverrides.borderWidthRange, step: 0.5, placeholder: 0.5)),
                default: nil, defaultLabel: SettingsText.keyed("settings.default.onePixel", "One pixel")
            ),
            SettingDescriptor(
                ["focusRing", "enabled"], section: .appearance, group: ring,
                title: SettingsText.keyed("settings.focusRing.enabled", "Show Focus Ring"),
                kind: .toggle, default: .bool(FocusRingSettings().enabled)
            ),
            SettingDescriptor(
                ["focusRing", "style"], section: .appearance, group: ring,
                title: SettingsText.keyed("settings.focusRing.style", "Style"),
                kind: .choice([
                    SettingChoice(FocusRingStyle.ring.rawValue, SettingsText.keyed("settings.choice.ring", "Ring")),
                    SettingChoice(FocusRingStyle.glow.rawValue, SettingsText.keyed("settings.choice.glow", "Glow")),
                    SettingChoice(FocusRingStyle.none.rawValue, SettingsText.keyed("settings.choice.none", "None")),
                ]),
                default: .string(FocusRingSettings().style.rawValue)
            ),
            SettingDescriptor(
                ["focusRing", "contrast"], section: .appearance, group: ring,
                title: SettingsText.keyed("settings.focusRing.contrast", "Contrast"),
                kind: .choice([
                    SettingChoice(FocusRingContrast.subtle.rawValue, SettingsText.keyed("settings.choice.subtle", "Subtle")),
                    SettingChoice(FocusRingContrast.standard.rawValue, SettingsText.keyed("settings.choice.standard", "Standard")),
                    SettingChoice(FocusRingContrast.strong.rawValue, SettingsText.keyed("settings.choice.strong", "Strong")),
                ]),
                default: .string(FocusRingSettings().contrast.rawValue)
            ),
            SettingDescriptor(
                ["focusRing", "color"], section: .appearance, group: ring,
                title: SettingsText.keyed("settings.focusRing.color", "Color"),
                kind: .color, default: nil, defaultLabel: theme
            ),
            SettingDescriptor(
                ["focusRing", "width"], section: .appearance, group: ring,
                title: SettingsText.keyed("settings.focusRing.width", "Width"),
                kind: .number(points(FocusRingSettings.widthRange, step: 0.5)),
                default: .number(Double(FocusRingSettings().width))
            ),
            SettingDescriptor(
                ["focusRing", "showWhenSinglePane"], section: .appearance, group: ring,
                title: SettingsText.keyed("settings.focusRing.showWhenSinglePane", "Show With One Pane"),
                kind: .toggle, default: .bool(FocusRingSettings().showsForSinglePane)
            ),
        ] + statusIndicator
    }

    /// `appearance.statusIndicator.*` (plans/cmux-next/status-indicators.md).
    static var statusIndicator: [SettingDescriptor] {
        let group = SettingsText.keyed("settings.group.statusIndicator", "Loading Indicator")
        let defaults = StatusIndicatorSettings()
        let path = StatusIndicatorConfigParser.path
        return [
            SettingDescriptor(
                path + ["style"], section: .appearance, group: group,
                title: SettingsText.keyed("settings.statusIndicator.style", "Style"),
                help: SettingsText.keyed("settings.statusIndicator.style.help", "How sidebar rows, tabs and panes show work in progress."),
                kind: .choice([
                    SettingChoice(StatusIndicatorStyle.arc.rawValue, SettingsText.keyed("settings.choice.thinArc", "Thin Arc")),
                    SettingChoice(StatusIndicatorStyle.native.rawValue, SettingsText.keyed("settings.choice.macSpinner", "macOS Spinner")),
                    SettingChoice(StatusIndicatorStyle.dot.rawValue, SettingsText.keyed("settings.choice.pulsingDot", "Pulsing Dot")),
                    SettingChoice(StatusIndicatorStyle.braille.rawValue, SettingsText.keyed("settings.choice.brailleSpinner", "Braille Spinner")),
                    SettingChoice(StatusIndicatorStyle.none.rawValue, SettingsText.keyed("settings.choice.none", "None")),
                ]),
                default: .string(defaults.style.rawValue), keywords: ["spinner", "progress", "loading", "busy"]
            ),
            SettingDescriptor(
                path + ["size"], section: .appearance, group: group,
                title: SettingsText.keyed("settings.statusIndicator.size", "Size"),
                kind: .number(SettingNumber(Double(StatusIndicatorSettings.scaleRange.lowerBound)...Double(StatusIndicatorSettings.scaleRange.upperBound),
                                            step: 0.05, unit: .fraction)),
                default: .number(Double(defaults.scale))
            ),
            SettingDescriptor(
                path + ["thickness"], section: .appearance, group: group,
                title: SettingsText.keyed("settings.statusIndicator.thickness", "Line Width"),
                kind: .number(points(StatusIndicatorSettings.thicknessRange, step: 0.25)), default: .number(Double(defaults.thickness))
            ),
            SettingDescriptor(
                path + ["color"], section: .appearance, group: group,
                title: SettingsText.keyed("settings.statusIndicator.color", "Color"),
                kind: .color, default: nil, defaultLabel: SettingsText.keyed("settings.default.theme", "Theme")
            ),
            SettingDescriptor(
                path + ["honorStatusStyle"], section: .appearance, group: group,
                title: SettingsText.keyed("settings.statusIndicator.honorStatusStyle", "Let Statuses Choose Their Style"),
                help: SettingsText.keyed("settings.statusIndicator.honorStatusStyle.help",
                                        "A status that asks for a style (cmux status set --style) uses it."),
                kind: .toggle, default: .bool(true)
            ),
            SettingDescriptor(
                StatusIndicatorConfigParser.behaviorPath + ["inferCommandBusy"], section: .appearance, group: group,
                title: SettingsText.keyed("settings.status.inferCommandBusy", "Show Running Commands"),
                help: SettingsText.keyed("settings.status.inferCommandBusy.help", "A shell command that runs a while shows as busy."),
                kind: .toggle, default: .bool(StatusBehaviorSettings().inferCommandBusy)
            ),
            SettingDescriptor(
                StatusIndicatorConfigParser.behaviorPath + ["inferCommandBusyAfter"], section: .appearance, group: group,
                title: SettingsText.keyed("settings.status.inferCommandBusyAfter", "Show After"),
                kind: .number(SettingNumber(StatusBehaviorSettings.inferAfterRange, step: 1, unit: .seconds)),
                default: .number(StatusBehaviorSettings().inferCommandBusyAfter)
            ),
        ]
    }

    static func points(_ range: ClosedRange<CGFloat>, step: Double, placeholder: Double? = nil) -> SettingNumber {
        SettingNumber(Double(range.lowerBound)...Double(range.upperBound), step: step, unit: .points, placeholder: placeholder)
    }
}
