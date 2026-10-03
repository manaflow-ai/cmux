public import CmuxNextActions
public import CmuxNextDesign
public import CoreGraphics

private nonisolated enum AppearanceSettingsSchema {
    static var descriptors: [SettingDescriptor] {
        let look = SettingsText.keyed("settings.group.densityMotion", "Density and Motion")
        let panes = SettingsText.keyed("settings.group.panes", "Panes")
        let ring = SettingsText.keyed("settings.group.focusRing", "Focus Ring")
        let densityDefault = SettingsText.keyed("settings.default.density", "Density default")
        let theme = SettingsText.keyed("settings.default.theme", "Theme")
        let window = SettingsText.keyed("settings.group.windowBackground", "Window Background")
        let ghostty = SettingsText.keyed("settings.default.ghosttyConfig", "Ghostty config")
        let appTheme = SettingsText.keyed("settings.group.appTheme", "App Theme")
        let tuning = SettingsText.keyed("settings.group.appearanceTuning", "Appearance Tuning")
        let artChoices = BackdropArt.allCases.map { SettingChoice($0.rawValue, $0.title) }
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
                BackdropArtSetting().configPath, section: .appearance, group: window,
                title: SettingsText.keyed("settings.appearance.backdropArt", "Backdrop Art"),
                help: SettingsText.keyed("settings.appearance.backdropArt.help",
                                        "A public-domain painting behind the window material. Lower Opacity to reveal it. Attribution is linked above."),
                kind: .choice([SettingChoice("none", SettingsText.keyed("settings.choice.none", "None"))] + artChoices),
                default: "none", keywords: ["painting", "art", "wallpaper", "backdrop", "attribution", "legacy"]
            ),
            SettingDescriptor(
                BackdropSelectionSetting().configPath, section: .appearance, group: window,
                title: SettingsText.keyed("settings.appearance.background", "Background"),
                help: SettingsText.keyed("settings.appearance.background.help",
                                        "Choose a bundled public-domain painting or a macOS system wallpaper behind the window material."),
                kind: .choice([SettingChoice("none", SettingsText.keyed("settings.choice.none", "None"))] + artChoices),
                default: "none", keywords: ["painting", "art", "wallpaper", "backdrop", "desktop", "attribution"]
            ),
            SettingDescriptor(
                ExperimentalAppearanceSetting().configPath, section: .appearance, group: window,
                title: SettingsText.keyed("settings.appearance.experimentalControls", "Experimental Appearance Controls"),
                help: SettingsText.keyed("settings.appearance.experimentalControls.help",
                                        "Show the wallpaper grid and live appearance tuner while they are being integrated."),
                kind: .toggle, default: .bool(false),
                keywords: ["experimental", "wallpaper", "tuner", "transparency", "hue", "saturation", "labs"]
            ),
            SettingDescriptor(
                AppearanceTuningSetting.glassTransparencyPath, section: .appearance, group: tuning,
                title: SettingsText.keyed("settings.appearance.glassTransparency", "Glass Transparency"),
                help: SettingsText.keyed("settings.appearance.glassTransparency.help",
                                        "How much of the desktop or wallpaper shows through the glass."),
                kind: .number(SettingNumber(AppearanceTuningSetting.glassTransparencyRange, step: 0.05, unit: .fraction, placeholder: 0)),
                default: .number(AppearanceTuningSetting.fallback.glassTransparency),
                keywords: ["glass", "transparency", "alpha", "clear"]
            ),
            SettingDescriptor(
                AppearanceTuningSetting.huePath, section: .appearance, group: tuning,
                title: SettingsText.keyed("settings.appearance.hue", "Hue"),
                help: SettingsText.keyed("settings.appearance.hue.help", "Shift the tint color around the hue wheel."),
                kind: .number(SettingNumber(AppearanceTuningSetting.hueRange, step: 0.05, unit: .fraction, placeholder: 0.5)),
                default: .number(AppearanceTuningSetting.fallback.hue),
                keywords: ["tint", "color", "colour"]
            ),
            SettingDescriptor(
                AppearanceTuningSetting.saturationPath, section: .appearance, group: tuning,
                title: SettingsText.keyed("settings.appearance.saturation", "Saturation"),
                help: SettingsText.keyed("settings.appearance.saturation.help", "Increase or reduce the tint color intensity."),
                kind: .number(SettingNumber(AppearanceTuningSetting.saturationRange, step: 0.05, unit: .fraction, placeholder: 1)),
                default: .number(AppearanceTuningSetting.fallback.saturation),
                keywords: ["tint", "color", "colour", "intensity"]
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
                kind: .number(appearancePoints(PaneChromeOverrides.paddingRange, step: 1, placeholder: 4)),
                default: nil, defaultLabel: densityDefault
            ),
            SettingDescriptor(
                ["layout", "paneCornerRadius"], section: .appearance, group: panes,
                title: SettingsText.keyed("settings.layout.paneCornerRadius", "Corner Radius"),
                kind: .number(appearancePoints(PaneChromeOverrides.cornerRadiusRange, step: 1, placeholder: 6)),
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
                kind: .number(appearancePoints(PaneChromeOverrides.borderWidthRange, step: 0.5, placeholder: 0.5)),
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
                kind: .number(appearancePoints(FocusRingSettings.widthRange, step: 0.5)),
                default: .number(Double(FocusRingSettings().width))
            ),
            SettingDescriptor(
                ["focusRing", "showWhenSinglePane"], section: .appearance, group: ring,
                title: SettingsText.keyed("settings.focusRing.showWhenSinglePane", "Show With One Pane"),
                kind: .toggle, default: .bool(FocusRingSettings().showsForSinglePane)
            ),
        ]
    }

    private static func appearancePoints(_ range: ClosedRange<CGFloat>, step: Double, placeholder: Double? = nil) -> SettingNumber {
        SettingNumber(Double(range.lowerBound)...Double(range.upperBound), step: step, unit: .points, placeholder: placeholder)
    }
}
