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
        general + appearance + browser + notifications
    }

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
        case .appearance: ["room.setTheme", "workspace.setTheme", "terminal.setTheme", "palette.openGhosttySettings"]
        case .terminal: ["palette.openGhosttySettings", "reloadConfiguration"]
        case .browser: ["browser.extensions.manage", "browser.extensions.webStore", "browser.extensions.loadUnpacked"]
        case .keyboard: ["palette.searchShortcuts"]
        case .notifications: []
        case .rooms: ["room.new", "room.switch", "room.rename", "room.setTheme", "room.clearTheme"]
        case .machines: ["remote.connect", "newCloudMachine", "palette.auth.signIn"]
        case .advanced: ["palette.openCmuxSettingsFile", "reloadConfiguration"]
        }
    }

    // MARK: General

    static var general: [SettingDescriptor] {
        let window = SettingsText.text("settings.group.window", "Window")
        let columns = SettingsText.text("settings.group.columns", "Columns")
        let quitting = SettingsText.text("settings.group.quit", "Quitting")
        return [
            SettingDescriptor(
                WindowTitlebarSetting.configPath, section: .general, group: window,
                title: SettingsText.text("settings.window.titlebar", "Titlebar"),
                help: SettingsText.text("settings.window.titlebar.help", "Minimal has no titlebar strip; the top row moves the window."),
                kind: .choice([
                    SettingChoice(TitlebarStyle.minimal.rawValue, SettingsText.text("settings.choice.minimal", "Minimal")),
                    SettingChoice(TitlebarStyle.standard.rawValue, SettingsText.text("settings.choice.standard", "Standard")),
                ]),
                default: .string(WindowTitlebarSetting.fallback.rawValue), keywords: ["traffic lights", "title"]
            ),
            SettingDescriptor(
                QuitBehaviorSetting.configPath, section: .general, group: quitting,
                title: SettingsText.text("settings.app.quitBehavior", "When Quitting"),
                help: SettingsText.text("settings.app.quitBehavior.help",
                                        "Terminals run in cmux-tui and keep running after cmux quits unless you end them."),
                kind: .choice([
                    SettingChoice(QuitBehavior.ask.rawValue, SettingsText.text("settings.choice.quitAsk", "Ask")),
                    SettingChoice(QuitBehavior.keep.rawValue, SettingsText.text("settings.choice.quitKeep", "Keep Sessions Running")),
                    SettingChoice(QuitBehavior.end.rawValue, SettingsText.text("settings.choice.quitEnd", "End All Sessions")),
                ]),
                default: .string(QuitBehaviorSetting.fallback.rawValue),
                keywords: ["quit", "exit", "sessions", "terminals", "cmux-tui", "daemon", "background"]
            ),
            SettingDescriptor(
                DefaultColumnWidthSetting.configPath, section: .general, group: columns,
                title: SettingsText.text("settings.layout.defaultColumnWidth", "New Column Width"),
                help: SettingsText.text("settings.layout.defaultColumnWidth.help", "A share of the window width."),
                kind: .number(SettingNumber(DefaultColumnWidthSetting.range, step: 0.05, unit: .fraction)),
                default: .number(DefaultColumnWidthSetting.fallback), keywords: ["niri", "width"]
            ),
            SettingDescriptor(
                CenterFocusedColumnSetting.configPath, section: .general, group: columns,
                title: SettingsText.text("settings.layout.centerFocusedColumn", "Center Focused Column"),
                kind: .choice([
                    SettingChoice(CenterFocusedColumn.never.rawValue, SettingsText.text("settings.choice.never", "Never")),
                    SettingChoice(CenterFocusedColumn.always.rawValue, SettingsText.text("settings.choice.always", "Always")),
                    SettingChoice(CenterFocusedColumn.onOverflow.rawValue, SettingsText.text("settings.choice.onOverflow", "When It Does Not Fit")),
                ]),
                default: .string(CenterFocusedColumnSetting.fallback.rawValue), keywords: ["niri", "scroll"]
            ),
        ]
    }

    // MARK: Appearance

    static var appearance: [SettingDescriptor] {
        let look = SettingsText.text("settings.group.densityMotion", "Density and Motion")
        let panes = SettingsText.text("settings.group.panes", "Panes")
        let ring = SettingsText.text("settings.group.focusRing", "Focus Ring")
        let densityDefault = SettingsText.text("settings.default.density", "Density default")
        let theme = SettingsText.text("settings.default.theme", "Theme")
        return [
            SettingDescriptor(
                ["appearance", "density"], section: .appearance, group: look,
                title: SettingsText.text("settings.appearance.density", "Density"),
                kind: .choice([
                    SettingChoice("compact", SettingsText.text("settings.choice.compact", "Compact")),
                    SettingChoice("comfortable", SettingsText.text("settings.choice.comfortable", "Comfortable")),
                ]),
                default: "compact", keywords: ["size", "spacing"]
            ),
            SettingDescriptor(
                AnimationSpeedSetting.configPath, section: .appearance, group: look,
                title: SettingsText.text("settings.ui.animationSpeed", "Animations"),
                kind: .choice([
                    SettingChoice(MotionSpeed.fast.rawValue, SettingsText.text("settings.choice.fast", "Fast")),
                    SettingChoice(MotionSpeed.normal.rawValue, SettingsText.text("settings.choice.normal", "Normal")),
                    SettingChoice(MotionSpeed.off.rawValue, SettingsText.text("settings.choice.off", "Off")),
                ]),
                default: .string(AnimationSpeedSetting.fallback.rawValue), keywords: ["motion", "speed"]
            ),
            SettingDescriptor(
                ["layout", "panePadding"], section: .appearance, group: panes,
                title: SettingsText.text("settings.layout.panePadding", "Padding"),
                kind: .number(points(PaneChromeOverrides.paddingRange, step: 1, placeholder: 4)),
                default: nil, defaultLabel: densityDefault
            ),
            SettingDescriptor(
                ["layout", "paneCornerRadius"], section: .appearance, group: panes,
                title: SettingsText.text("settings.layout.paneCornerRadius", "Corner Radius"),
                kind: .number(points(PaneChromeOverrides.cornerRadiusRange, step: 1, placeholder: 6)),
                default: nil, defaultLabel: densityDefault, keywords: ["rounded"]
            ),
            SettingDescriptor(
                ["layout", "paneBorder"], section: .appearance, group: panes,
                title: SettingsText.text("settings.layout.paneBorder", "Border"),
                kind: .choice([
                    SettingChoice(PaneBorderStyle.subtle.rawValue, SettingsText.text("settings.choice.subtle", "Subtle")),
                    SettingChoice(PaneBorderStyle.none.rawValue, SettingsText.text("settings.choice.none", "None")),
                ]),
                default: .string(PaneBorderStyle.subtle.rawValue)
            ),
            SettingDescriptor(
                ["layout", "paneBorderColor"], section: .appearance, group: panes,
                title: SettingsText.text("settings.layout.paneBorderColor", "Border Color"),
                kind: .color, default: nil, defaultLabel: theme
            ),
            SettingDescriptor(
                ["layout", "paneBorderWidth"], section: .appearance, group: panes,
                title: SettingsText.text("settings.layout.paneBorderWidth", "Border Width"),
                kind: .number(points(PaneChromeOverrides.borderWidthRange, step: 0.5, placeholder: 0.5)),
                default: nil, defaultLabel: SettingsText.text("settings.default.onePixel", "One pixel")
            ),
            SettingDescriptor(
                ["focusRing", "enabled"], section: .appearance, group: ring,
                title: SettingsText.text("settings.focusRing.enabled", "Show Focus Ring"),
                kind: .toggle, default: .bool(FocusRingSettings().enabled)
            ),
            SettingDescriptor(
                ["focusRing", "style"], section: .appearance, group: ring,
                title: SettingsText.text("settings.focusRing.style", "Style"),
                kind: .choice([
                    SettingChoice(FocusRingStyle.ring.rawValue, SettingsText.text("settings.choice.ring", "Ring")),
                    SettingChoice(FocusRingStyle.glow.rawValue, SettingsText.text("settings.choice.glow", "Glow")),
                    SettingChoice(FocusRingStyle.none.rawValue, SettingsText.text("settings.choice.none", "None")),
                ]),
                default: .string(FocusRingSettings().style.rawValue)
            ),
            SettingDescriptor(
                ["focusRing", "color"], section: .appearance, group: ring,
                title: SettingsText.text("settings.focusRing.color", "Color"),
                kind: .color, default: nil, defaultLabel: theme
            ),
            SettingDescriptor(
                ["focusRing", "width"], section: .appearance, group: ring,
                title: SettingsText.text("settings.focusRing.width", "Width"),
                kind: .number(points(FocusRingSettings.widthRange, step: 0.5)),
                default: .number(Double(FocusRingSettings().width))
            ),
            SettingDescriptor(
                ["focusRing", "showWhenSinglePane"], section: .appearance, group: ring,
                title: SettingsText.text("settings.focusRing.showWhenSinglePane", "Show With One Pane"),
                kind: .toggle, default: .bool(FocusRingSettings().showsForSinglePane)
            ),
        ]
    }

    static func points(_ range: ClosedRange<CGFloat>, step: Double, placeholder: Double? = nil) -> SettingNumber {
        SettingNumber(Double(range.lowerBound)...Double(range.upperBound), step: step, unit: .points, placeholder: placeholder)
    }
}
