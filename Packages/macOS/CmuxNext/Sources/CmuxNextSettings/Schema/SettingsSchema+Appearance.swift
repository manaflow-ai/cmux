public import CmuxNextActions
public import CmuxNextDesign
public import CoreGraphics

nonisolated enum AppearanceSettingsSchema {
    static var descriptors: [SettingDescriptor] {
        let uiScale = UIScaleSetting()
        let look = SettingsText.keyed("settings.group.densityMotion", "Density and Motion")
        let panes = SettingsText.keyed("settings.group.panes", "Panes")
        let ring = SettingsText.keyed("settings.group.focusRing", "Focus Ring")
        let densityDefault = SettingsText.keyed("settings.default.density", "Density default")
        let theme = SettingsText.keyed("settings.default.theme", "Theme")
        let window = SettingsText.keyed("settings.group.windowBackground", "Window Background")
        let ghostty = SettingsText.keyed("settings.source.ghostty", "Ghostty")
        let appTheme = SettingsText.keyed("settings.group.appTheme", "App Theme")
        let tuning = SettingsText.keyed("settings.group.appearanceTuning", "Appearance Tuning")
        let artChoices = BackdropArt.allCases.map { SettingChoice($0.rawValue, $0.label) }
        // The background picker lists art by collection, Dark Art first.
        let backgroundChoices = BackdropCatalog.bundled.map { SettingChoice($0.id, $0.title) } + [SettingChoice(BackdropSelection.desktopID, SettingsText.keyed("settings.choice.desktopWallpaper", "Desktop Wallpaper"))]
        return [
            SettingDescriptor(
                AppThemeSetting().configPath, section: .appearance, group: appTheme,
                title: SettingsText.keyed("settings.appearance.theme", "Theme"),
                help: SettingsText.keyed("settings.appearance.theme.help",
                                        "Colors for cmux and its terminals. A space, workspace or terminal theme overrides it."),
                summary: SettingsText.keyed("settings.appearance.theme.summary", "Colors for cmux and its terminals"),
                kind: .theme, default: nil, defaultLabel: ghostty,
                keywords: ["theme", "color", "colors", "color scheme", "dark", "light", "ghostty", "palette"]
            ),
            SettingDescriptor(
                ChromeThemeSetting().configPath, section: .appearance, group: appTheme,
                title: SettingsText.keyed("settings.appearance.appTheme", "App Theme"),
                help: SettingsText.keyed("settings.appearance.appTheme.help",
                                        "Colors for cmux's own pages. Every bundled theme works here, and each color meets WCAG AA contrast."),
                summary: SettingsText.keyed("settings.appearance.appTheme.summary", "Colors for cmux's own pages"),
                kind: .theme, default: .string(ChromeThemeSetting.followTerminal),
                defaultLabel: SettingsText.keyed("settings.default.followTerminal", "Match Terminal Theme"),
                keywords: ["app theme", "accent", "chrome", "interface", "colors", "contrast", "wcag"]
            ),
            SettingDescriptor(
                ThemeEditsSetting().configPath, section: .appearance, group: appTheme,
                title: SettingsText.keyed("settings.appearance.themeEdits", "Theme Edits"),
                help: SettingsText.keyed("settings.appearance.themeEdits.help",
                                        "Your color changes to a theme, such as \"Rose Pine/background\": \"#1f1d2e\". The theme itself never changes; remove an entry to reset that color."),
                kind: .stringMap, default: .object([:]),
                keywords: ["theme", "custom", "edit", "color", "colour", "palette", "background", "foreground", "cursor", "selection"]
            ),
            SettingDescriptor(
                AccentSetting().configPath, section: .appearance, group: appTheme,
                title: SettingsText.keyed("settings.appearance.accent", "Accent"),
                help: SettingsText.keyed("settings.appearance.accent.help",
                                        "The color of selection, focus and the Send button. Theme Color takes the theme's own hue, such as Rose Pine's iris."),
                summary: SettingsText.keyed("settings.appearance.accent.summary", "Color of selection and focus"),
                kind: .choice([
                    SettingChoice(ThemeAccent.neutral.rawValue, SettingsText.keyed("settings.choice.accent.neutral", "Neutral")),
                    SettingChoice(ThemeAccent.theme.rawValue, SettingsText.keyed("settings.choice.accent.theme", "Theme Color")),
                    SettingChoice(AccentSetting.artID, SettingsText.keyed("settings.choice.accent.art", "Art Color")),
                    SettingChoice(ThemeAccent.red.rawValue, SettingsText.keyed("settings.choice.accent.red", "Red")),
                    SettingChoice(ThemeAccent.green.rawValue, SettingsText.keyed("settings.choice.accent.green", "Green")),
                    SettingChoice(ThemeAccent.yellow.rawValue, SettingsText.keyed("settings.choice.accent.yellow", "Yellow")),
                    SettingChoice(ThemeAccent.blue.rawValue, SettingsText.keyed("settings.choice.accent.blue", "Blue")),
                    SettingChoice(ThemeAccent.magenta.rawValue, SettingsText.keyed("settings.choice.accent.magenta", "Magenta")),
                    SettingChoice(ThemeAccent.cyan.rawValue, SettingsText.keyed("settings.choice.accent.cyan", "Cyan")),
                ]),
                default: .string(ThemeAccent.neutral.rawValue),
                keywords: ["accent", "color", "colour", "highlight", "selection", "personality", "rose pine", "ansi"]
            ),
            SettingDescriptor(
                BackdropArtSetting().configPath, section: .appearance, group: window,
                title: SettingsText.keyed("settings.appearance.backdropArt", "Backdrop Art"),
                help: SettingsText.keyed("settings.appearance.backdropArt.help",
                                        "A public-domain painting behind the window material. Lower Opacity to reveal it. Attribution is linked above."),
                summary: SettingsText.keyed("settings.appearance.backdropArt.summary", "Painting behind the window"),
                kind: .choice([SettingChoice("none", SettingsText.keyed("settings.choice.none", "None"))] + artChoices),
                default: "none", keywords: ["painting", "art", "wallpaper", "backdrop", "attribution", "legacy"]
            // A second painting chooser beside the wallpaper card (Leo, 10-19: "it just doesn't make
            // sense"). The key still loads; appearance.background wins when both are set.
            ).hiddenFromSettingsPage("legacy: the wallpaper card's appearance.background replaces it; the key still loads"),
            SettingDescriptor(
                BackdropSelectionSetting().configPath, section: .appearance, group: window,
                title: SettingsText.keyed("settings.appearance.background", "Background"),
                help: SettingsText.keyed("settings.appearance.background.help",
                                        "Choose a public-domain painting, your desktop wallpaper, or a macOS system wallpaper behind the window material."),
                summary: SettingsText.keyed("settings.appearance.background.summary", "Image behind your terminals"),
                kind: .choice([SettingChoice("none", SettingsText.keyed("settings.choice.none", "None")),
                               SettingChoice(BackdropSelectionSetting.dailyID,
                                             SettingsText.keyed("settings.choice.shufflePaintings", "Shuffle Paintings"))] + backgroundChoices),
                default: .string(BackdropSelectionSetting.defaultSelection?.id ?? "none"),
                keywords: ["painting", "art", "wallpaper", "backdrop", "desktop", "attribution", "museum", "dark", "doré", "shuffle", "folder"]
            ),
            SettingDescriptor(
                BackdropSelectionSetting.rotationPath, section: .appearance, group: window,
                title: SettingsText.keyed("settings.appearance.backgroundRotation", "Change Picture"),
                help: SettingsText.keyed("settings.appearance.backgroundRotation.help", "How often a shuffled background turns to its next picture."),
                summary: SettingsText.keyed("settings.appearance.backgroundRotation.summary", "How often Shuffle changes the picture"),
                kind: .choice([SettingChoice("15m", SettingsText.keyed("settings.choice.every15Minutes", "Every 15 Minutes")),
                               SettingChoice("hourly", SettingsText.keyed("settings.choice.everyHour", "Every Hour")),
                               SettingChoice("daily", SettingsText.keyed("settings.choice.everyDay", "Every Day"))]),
                default: .string(BackdropRotation.defaultRotation.rawValue),
                keywords: ["shuffle", "rotate", "rotating", "wallpaper", "interval", "change picture", "background"]
            ),
            PaneBackgroundsSetting.descriptor(group: window),
            ReducedBackgroundsSetting.descriptor(group: window),
            SettingDescriptor(
                ExperimentalAppearanceSetting().configPath, section: .appearance, group: window,
                title: SettingsText.keyed("settings.appearance.experimentalControls", "Experimental Appearance Controls"),
                help: SettingsText.keyed("settings.appearance.experimentalControls.help",
                                        "Applies Hue and Saturation to the window's tint. Off, they have no effect."),
                kind: .toggle, default: .bool(false),
                keywords: ["experimental", "tuning", "tint", "transparency", "hue", "saturation", "labs"]
            ),
            SettingDescriptor(
                WindowBackgroundSetting.opacityPath, section: .appearance, group: window,
                title: SettingsText.keyed("settings.appearance.backgroundOpacity", "Opacity"),
                help: SettingsText.keyed("settings.appearance.backgroundOpacity.help",
                                        "How much of the theme color covers the material behind the window."),
                summary: SettingsText.keyed("settings.appearance.backgroundOpacity.summary", "Theme color over the backdrop"),
                kind: .number(SettingNumber(WindowBackgroundSetting.opacityRange, step: 0.05, unit: .fraction, placeholder: 1)),
                default: nil, defaultLabel: ghostty,
                keywords: ["transparency", "translucent", "background-opacity", "blur", "glass"]
            ),
            SettingDescriptor(
                WindowBackgroundSetting.materialPath, section: .appearance, group: window,
                title: SettingsText.keyed("settings.appearance.backgroundBlur", "Material"),
                help: SettingsText.keyed("settings.appearance.backgroundBlur.help",
                                        "Unset, the window follows Ghostty's background-opacity and background-blur."),
                summary: SettingsText.keyed("settings.appearance.backgroundBlur.summary",
                                           "Clear Glass shows the desktop through the wallpaper"),
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
                WindowBackgroundSetting.inactiveDimPath, section: .appearance, group: window,
                title: SettingsText.keyed("settings.appearance.inactiveWindowDim", "Dim Inactive Windows"),
                help: SettingsText.keyed("settings.appearance.inactiveWindowDim.help",
                                        "How much more theme color covers a window while another one is in front. 0 keeps the same look."),
                kind: .number(SettingNumber(WindowBackgroundSetting.inactiveDimRange, step: 0.05, unit: .fraction, placeholder: 0)),
                default: .number(0),
                keywords: ["inactive", "unfocused", "focus", "dim", "opacity", "transparency", "background"]
            ),
            SettingDescriptor(
                WallpaperTintSetting().configPath, section: .appearance, group: window,
                title: SettingsText.keyed("settings.appearance.wallpaperTint", "Tint with Desktop Wallpaper"),
                help: SettingsText.keyed("settings.appearance.wallpaperTint.help",
                                        "The glass takes the colors of your desktop picture and follows it when the picture or Space changes."),
                kind: .toggle, default: .bool(WallpaperTintSetting.fallback),
                keywords: ["wallpaper", "desktop", "tint", "tinting", "glass", "color", "colour", "space", "background"]
            ),
            SettingDescriptor(
                AppearanceTuningSetting.glassTransparencyPath, section: .appearance, group: tuning,
                title: SettingsText.keyed("settings.appearance.glassTransparency", "Glass Transparency"),
                help: SettingsText.keyed("settings.appearance.glassTransparency.help",
                                        "How much of the desktop or wallpaper shows through the glass."),
                kind: .number(SettingNumber(AppearanceTuningSetting.glassTransparencyRange, step: 0.05, unit: .fraction, placeholder: 0)),
                default: .number(AppearanceTuningSetting.fallback.glassTransparency),
                keywords: ["glass", "transparency", "alpha", "clear"]
            // A second opacity over the wallpaper card's Opacity (Leo, 10-19: "this other
            // transparency situation"). It still applies with Experimental Appearance Controls on.
            ).hiddenFromSettingsPage("duplicates appearance.backgroundOpacity; the key still loads"),
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
                ["appearance", "density"], section: .appearance, group: look,
                title: SettingsText.keyed("settings.appearance.density", "Density"),
                help: SettingsText.keyed("settings.appearance.density.help",
                                        "Row height, padding, corners, icons and text size together. Compact is the default."),
                kind: .choice(DensityPreset.allCases.map { SettingChoice($0.rawValue, DensityNames.title($0)) }),
                default: "compact", keywords: ["size", "spacing", "compact", "comfortable", "cozy", "spacious", "dense", "font"]
            ),
            SettingDescriptor(
                CustomDensitySelectionSetting().configPath, section: .appearance, group: look,
                title: SettingsText.keyed("settings.appearance.customDensity", "Custom Density"),
                kind: .text, default: nil, keywords: ["density", "custom"]
            ).hiddenFromPalette("the Density card and the palette's density rows pick it"),
            SettingDescriptor(
                CustomDensitiesSetting().configPath, section: .appearance, group: look,
                title: SettingsText.keyed("settings.appearance.customDensities", "Custom Densities"),
                kind: .text, default: .array([]), keywords: ["density", "custom"]
            ).hiddenFromPalette("the Density card edits them: a list of density objects"),
            SettingDescriptor(
                uiScale.configPath, section: .appearance, group: look,
                title: SettingsText.keyed("settings.appearance.uiScale", "Interface Scale"),
                kind: .number(SettingNumber(uiScale.range, step: uiScale.step, unit: .fraction, placeholder: uiScale.fallback)),
                default: .number(uiScale.fallback),
                keywords: ["scale", "zoom", "size", "chrome", "web", "bigger", "smaller"]
            ),
            SettingDescriptor(
                ["appearance", "metrics", "chromeFontSize"], section: .appearance, group: look,
                title: SettingsText.keyed("settings.appearance.interfaceSize", "Interface Size"),
                help: SettingsText.keyed("settings.appearance.interfaceSize.help", "Text size of tabs, the sidebar and other controls. Terminal text has its own size."),
                kind: .number(SettingNumber(10...16, step: 1, unit: .points, placeholder: 12)),
                default: nil, defaultLabel: densityDefault,
                keywords: ["font", "text", "size", "chromeFontSize"]
            ),
            SettingDescriptor(
                InterfaceScaleSetting().configPath, section: .appearance, group: look,
                title: SettingsText.keyed("settings.appearance.interfaceSize", "Interface Size"),
                help: SettingsText.keyed("settings.appearance.interfaceSize.help",
                                        "Text size of tabs, the sidebar and other controls. Terminal text has its own size."),
                summary: SettingsText.keyed("settings.appearance.interfaceSize.summary", "Text size of tabs, sidebar and controls"),
                kind: .number(SettingNumber(InterfaceScaleSetting().range, step: InterfaceScaleSetting().step, unit: .fraction, placeholder: InterfaceScaleSetting().fallback)),
                default: nil, defaultLabel: densityDefault,
                keywords: ["font", "text", "size", "zoom", "scale", "bigger", "smaller", "interfaceScale"]
            ).hiddenFromSettingsPage("opt-in: the Debug Settings toggle chrome.interfaceSize turns it on, until it is promoted"),
            metric(.sidebarWidth, SettingsText.keyed("settings.appearance.sidebarWidth", "Sidebar Width"), look, densityDefault,
                   keywords: ["sidebar", "width", "size", "sidebarWidth"]),
            metric(.columnGap, SettingsText.keyed("settings.appearance.columnGap", "Column Gap"), look, densityDefault,
                   keywords: ["column", "gap", "spacing", "columnGap"]),
            metric(.dividerThickness, SettingsText.keyed("settings.appearance.dividerThickness", "Divider Thickness"), look, densityDefault,
                   consumers: [.cmuxNext], keywords: ["divider", "split", "pane", "line", "thickness", "dividerThickness"]),
            metric(.dividerHitWidth, SettingsText.keyed("settings.appearance.dividerHitWidth", "Divider Drag Width"), look, densityDefault,
                   consumers: [.cmuxNext], keywords: ["divider", "split", "pane", "drag", "hit", "width", "dividerHitWidth"]),
            metric(.titlebarHeight, SettingsText.keyed("settings.appearance.titlebarHeight", "Titlebar Height"), look, densityDefault,
                   keywords: ["titlebar", "title bar", "header", "height", "titlebarHeight"]),
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
                summary: SettingsText.keyed("settings.appearance.focusIndicator.summary", "How the focused pane stands out"),
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
                                        "How the other panes' tabs draw subtler when Focused Pane marks tabs: Fade dims them, Tonal steps their text down, Quiet keeps only a faint selected pill."),
                summary: SettingsText.keyed("settings.focus.inactiveTabStyle.summary", "How tabs in other panes tone down"),
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
            ChromeStyleSetting.descriptor(group: panes),
            SettingDescriptor(
                PaneAnimationsSetting.configPath, section: .appearance, group: look,
                title: SettingsText.keyed("settings.ui.paneAnimations", "Animate Panes"),
                help: SettingsText.keyed("settings.ui.paneAnimations.help",
                                        "Splits, closes, moves, zooms, column scrolls and screen switches slide into place. Off: they change at once."),
                kind: .toggle, default: .bool(PaneAnimationsSetting.fallback),
                keywords: ["motion", "animation", "pane", "split", "zoom", "slide", "spring"]
            ),
            SettingDescriptor(
                AnimationKindsSetting.path(.newTab), section: .appearance, group: look,
                title: SettingsText.keyed("settings.ui.animations.newTab", "Animate New Tabs"),
                help: SettingsText.keyed("settings.ui.animations.newTab.help",
                                        "A new tab grows into its place in the tab bar. Off shows it there at once."),
                kind: .toggle, default: .bool(AnimationKindsSetting.defaultEnabled.contains(.newTab)), keywords: ["motion", "animation", "tab"]
            ),
            SettingDescriptor(
                AnimationKindsSetting.path(.newWorkspace), section: .appearance, group: look,
                title: SettingsText.keyed("settings.ui.animations.newWorkspace", "Animate New Workspaces"),
                help: SettingsText.keyed("settings.ui.animations.newWorkspace.help",
                                        "A new workspace row opens in the sidebar. Off shows it there at once."),
                kind: .toggle, default: .bool(AnimationKindsSetting.defaultEnabled.contains(.newWorkspace)), keywords: ["motion", "animation", "workspace", "sidebar"]
            ),
            SettingDescriptor(
                AnimationKindsSetting.bouncePath, section: .appearance, group: look,
                title: SettingsText.keyed("settings.ui.animations.bounce", "Animation Bounce"),
                help: SettingsText.keyed("settings.ui.animations.bounce.help",
                                        "None stops tabs, rows and panes exactly at their place. Subtle lets them settle with a small bounce."),
                kind: .choice([
                    SettingChoice(MotionBounce.none.rawValue, SettingsText.keyed("settings.choice.none", "None")),
                    SettingChoice(MotionBounce.subtle.rawValue, SettingsText.keyed("settings.choice.subtle", "Subtle")),
                ]),
                default: .string(AnimationKindsSetting.bounceFallback.rawValue), keywords: ["motion", "spring", "bounce"]
            ),
            SettingDescriptor(
                ["layout", "paneSeparation"], section: .appearance, group: panes,
                title: SettingsText.keyed("settings.layout.paneSeparation", "Separation"),
                help: SettingsText.keyed("settings.layout.paneSeparation.help",
                                        "How panes are told apart. None draws no border or divider at all; dragging between panes still resizes them. Default: dividers inside the curved main pane, borders otherwise."),
                summary: SettingsText.keyed("settings.layout.paneSeparation.summary", "How panes are told apart"),
                kind: .choice([
                    SettingChoice(PaneSeparation.none.rawValue, SettingsText.keyed("settings.choice.none", "None")),
                    SettingChoice(PaneSeparation.dividers.rawValue, SettingsText.keyed("settings.choice.dividers", "Dividers")),
                    SettingChoice(PaneSeparation.borders.rawValue, SettingsText.keyed("settings.choice.borders", "Borders")),
                    SettingChoice(PaneSeparation.cards.rawValue, SettingsText.keyed("settings.choice.cards", "Cards")),
                ]),
                // The default depends on the curved main pane (`Metrics.defaultPaneSeparation`).
                default: nil, defaultLabel: SettingsText.keyed("settings.choice.default", "Default"),
                keywords: ["border", "divider", "separator", "gap", "cards", "lines", "seamless", "pane"]
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

    /// An `appearance.metrics.*` size row: its default is the density's (the compact one is the
    /// placeholder). cmux-next and cmux-browser read it.
    private static func metric(_ metric: LayoutMetricSetting, _ title: SettingText, _ group: SettingText, _ densityDefault: SettingText,
                               consumers: Set<SettingConsumer> = [.cmuxNext, .cmuxBrowser], keywords: [String]) -> SettingDescriptor {
        SettingDescriptor(
            metric.configPath, section: .appearance, group: group, title: title,
            kind: .number(SettingNumber(metric.range, step: 1, unit: .points, placeholder: metric.compact)),
            default: nil, defaultLabel: densityDefault, keywords: keywords
        ).consumed(by: consumers)
    }
}
