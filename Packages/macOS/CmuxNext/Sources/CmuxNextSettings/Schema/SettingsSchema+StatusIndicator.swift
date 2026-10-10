import CmuxNextDesign

/// Appearance status indicator descriptors kept separate from the main schema list.
/// One group of `SettingsSchema` rows (its own type: the schema type's line budget is per type).
nonisolated enum StatusIndicatorSettingsSchema {
    /// `appearance.statusIndicator.*` (plans/cmux-next/status-indicators.md).
    static var descriptors: [SettingDescriptor] {
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
                kind: .number(SettingsSchema.points(StatusIndicatorSettings.thicknessRange, step: 0.25)), default: .number(Double(defaults.thickness))
            ),
            SettingDescriptor(
                path + ["color"], section: .appearance, group: group,
                title: SettingsText.keyed("settings.statusIndicator.color", "Color"),
                kind: .color, default: nil, defaultLabel: SettingsText.keyed("settings.default.theme", "Theme")
            ),
            SettingDescriptor(
                path + ["showAgentWorkingOnTabs"], section: .appearance, group: group,
                title: SettingsText.keyed("settings.statusIndicator.showAgentWorkingOnTabs", "Show Agent Working on Tabs"),
                help: SettingsText.keyed("settings.statusIndicator.showAgentWorkingOnTabs.help",
                                        "Three dots take the tab's icon place while an agent works."),
                kind: .toggle, default: .bool(defaults.showsAgentWorkingOnTabs), keywords: ["agent", "working", "thinking", "dots"]
            ),
            SettingDescriptor(
                path + ["showPageLoading"], section: .appearance, group: group,
                title: SettingsText.keyed("settings.statusIndicator.showPageLoading", "Show Page Loading on Tabs"),
                help: SettingsText.keyed("settings.statusIndicator.showPageLoading.help",
                                        "A spinner takes a browser tab's icon place while its page loads."),
                kind: .toggle, default: .bool(defaults.showsPageLoading), keywords: ["browser", "loading", "spinner", "page"]
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
}

